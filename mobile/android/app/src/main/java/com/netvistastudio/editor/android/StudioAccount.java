package com.netvistastudio.editor.android;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.net.ssl.HttpsURLConnection;
import java.net.URL;

/** Same hosted REST account provider as desktop. No secret/service-role key. */
public final class StudioAccount {
    private static final String AUTH_URL = "https://tsitgxafmtzjgtmiczsq.supabase.co/auth/v1/";
    private static final String PUBLIC_KEY = "sb_publishable__tAdP-Xsu5Gh2ImdKvOHnw_WVujAfJh";
    public static final String ACCOUNT_URL = "https://video.netvistastudio.com/account/";
    private static StudioAccount instance;

    public interface Listener { void changed(Snapshot state); }
    public static final class Snapshot {
        public final boolean canEdit;
        public final boolean busy;
        public final String email;
        public final String status;
        Snapshot(boolean canEdit, boolean busy, String email, String status) {
            this.canEdit = canEdit; this.busy = busy; this.email = email; this.status = status;
        }
    }
    private static final class Failure extends IOException {
        final int status; final String code;
        Failure(int status, String code) { super("Account request failed."); this.status = status; this.code = code; }
    }
    private final EncryptedSessionStore store;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private final CopyOnWriteArrayList<Listener> listeners = new CopyOnWriteArrayList<>();
    private JSONObject session;
    private boolean remember = true;
    private boolean storageWarning;
    private long lastVerified;
    private long lastAttempt;
    private long retryAt;
    private volatile Snapshot snapshot = new Snapshot(false, true, "", "Checking saved sign-in…");

    public static synchronized StudioAccount get(Context context) {
        if (instance == null) instance = new StudioAccount(context.getApplicationContext());
        return instance;
    }
    private StudioAccount(Context context) {
        store = new EncryptedSessionStore(context);
        worker.execute(() -> {
            synchronized (this) {
                try {
                    String saved = store.load();
                    if (saved != null) {
                        session = decodeSession(new JSONObject(saved));
                        lastVerified = session.optLong("last_verified_ms", 0);
                    }
                    publish(false, session == null ? "Sign in with your NetVista account. Videos stay on this device."
                            : "Saved sign-in restored. Checking account…");
                } catch (Exception e) {
                    session = null; lastVerified = 0;
                    publish(false, "Saved sign-in is unavailable. Please sign in again.");
                }
            }
            checkBlocking(true);
        });
    }
    public Snapshot state() { return snapshot; }
    public void addListener(Listener listener) { listeners.add(listener); main.post(() -> listener.changed(snapshot)); }
    public void removeListener(Listener listener) { listeners.remove(listener); }

    private void publish(boolean busy, String message) {
        String email = session == null ? "" : session.optJSONObject("user").optString("email", "");
        snapshot = new Snapshot(session != null && lastVerified > 0, busy, email, message);
        Snapshot update = snapshot;
        main.post(() -> { for (Listener listener : listeners) listener.changed(update); });
    }

    public void signIn(String email, String password, boolean rememberOnDevice) {
        worker.execute(() -> {
            synchronized (this) {
                if (snapshot.busy) return;
                if (!email.contains("@") || password.isEmpty()) { publish(false, "Enter your email and password."); return; }
                publish(true, "Signing in securely…");
                try {
                    JSONObject body = new JSONObject().put("email", email.trim()).put("password", password);
                    JSONObject value = decodeSession(request("token?grant_type=password", body, null));
                    // A token response's embedded user is not sufficient validation.
                    JSONObject user = request("user", null, value.getString("access_token"));
                    checkUser(value, user);
                    value.put("user", user); session = value;
                    remember = rememberOnDevice; lastVerified = System.currentTimeMillis();
                    lastAttempt = lastVerified; retryAt = 0; persist();
                    publish(false, successMessage());
                } catch (Failure e) {
                    publish(false, "email_not_confirmed".equals(e.code)
                            ? "Confirm your email before signing in." : "Sign-in failed. Check your details or try again later.");
                } catch (Exception e) { publish(false, "Sign-in could not be verified. Check your connection and try again."); }
            }
        });
    }

    public void checkAsync(boolean force) { worker.execute(() -> checkBlocking(force)); }

    /** Called by the native background job and foreground timer, serialized with sign-in/refresh. */
    public synchronized void checkBlocking(boolean force) {
        if (session == null || snapshot.busy) return;
        long now = System.currentTimeMillis();
        if (now < retryAt || (!force && !AuthPolicy.due(now, lastAttempt, retryAt, session.optLong("expires_at")))) return;
        lastAttempt = now; publish(true, "Checking your account…");
        try {
            if (session.optLong("expires_at") * 1000 <= now + 60000) refresh();
            JSONObject user;
            try { user = request("user", null, session.getString("access_token")); }
            catch (Failure failure) {
                if (failure.status != 401 || "user_not_found".equals(failure.code)
                        || "session_not_found".equals(failure.code)) throw failure;
                refresh(); user = request("user", null, session.getString("access_token"));
            }
            checkUser(session, user); session.put("user", user);
            lastVerified = System.currentTimeMillis(); retryAt = 0; persist();
            publish(false, successMessage());
        } catch (Failure failure) {
            if (AuthPolicy.rejectsSession(failure.status, failure.code)) {
                session = null; lastVerified = 0;
                try { store.clear(); publish(false, "Your account or session is unavailable. Sign in again. Your project is safe."); }
                catch (Exception e) { publish(false, "Session revoked. Saved sign-in could not be removed. Your project is safe."); }
            } else postponed();
        } catch (Exception e) { postponed(); }
    }

    private void postponed() {
        retryAt = System.currentTimeMillis() + 60000;
        lastAttempt = retryAt - AuthPolicy.CHECK_INTERVAL_MS;
        publish(false, "Account check postponed: connection unavailable. Your work is safe; we'll retry.");
    }
    private String successMessage() {
        return storageWarning ? "Account verified. Secure storage unavailable; sign-in may not survive restart."
                : "Account verified. Rechecking every 25 minutes—no password needed.";
    }
    private void refresh() throws Exception {
        JSONObject old = session;
        JSONObject value = decodeSession(request("token?grant_type=refresh_token",
                new JSONObject().put("refresh_token", old.getString("refresh_token")), null));
        checkUser(old, value.getJSONObject("user"));
        session = value;
        // Persist rotated credentials before getUser: a temporary connection failure
        // must not strand this device with an already-used refresh token.
        persist();
    }
    private static void checkUser(JSONObject value, JSONObject user) throws Exception {
        String id = user.optString("id", "");
        if (id.isEmpty() || !id.equals(value.getJSONObject("user").getString("id"))) {
            throw new Failure(401, "user_not_found");
        }
    }
    private static JSONObject decodeSession(JSONObject value) throws Exception {
        if (value.getString("access_token").isEmpty() || value.getString("refresh_token").isEmpty()
                || value.getJSONObject("user").getString("id").isEmpty()) throw new IOException("Invalid session response.");
        if (!value.has("expires_at")) value.put("expires_at", System.currentTimeMillis() / 1000 + value.optLong("expires_in", 3600));
        return value;
    }
    private void persist() {
        try {
            if (remember && session != null) { session.put("last_verified_ms", lastVerified); store.save(session.toString()); }
            else store.clear();
            storageWarning = false;
        } catch (Exception e) { storageWarning = true; } // Never fall back to plaintext.
    }
    public void signOut() {
        worker.execute(() -> {
            String token;
            synchronized (this) {
                token = session == null ? null : session.optString("access_token", null);
                session = null; lastVerified = 0; lastAttempt = 0; retryAt = 0;
                try { store.clear(); publish(false, "Signed out on this device. Your saved projects are untouched."); }
                catch (Exception e) { publish(false, "Signed out in memory. Secure storage could not be cleared; avoid sharing this device."); }
            }
            if (token != null) { try { request("logout?scope=local", new JSONObject(), token); } catch (Exception ignored) { /* local sign-out already applied */ } }
        });
    }

    private static JSONObject request(String path, JSONObject body, String accessToken) throws Exception {
        HttpsURLConnection connection = (HttpsURLConnection) new URL(AUTH_URL + path).openConnection();
        connection.setInstanceFollowRedirects(false); connection.setUseCaches(false);
        connection.setConnectTimeout(20000); connection.setReadTimeout(20000);
        connection.setRequestProperty("apikey", PUBLIC_KEY);
        connection.setRequestProperty("Content-Type", "application/json");
        connection.setRequestProperty("Accept", "application/json");
        if (accessToken != null) connection.setRequestProperty("Authorization", "Bearer " + accessToken);
        try {
            if (body != null) {
                byte[] payload = body.toString().getBytes(StandardCharsets.UTF_8);
                connection.setRequestMethod("POST"); connection.setDoOutput(true); connection.setFixedLengthStreamingMode(payload.length);
                try (java.io.OutputStream output = connection.getOutputStream()) { output.write(payload); }
            }
            int status = connection.getResponseCode();
            InputStream input = status >= 200 && status < 300 ? connection.getInputStream() : connection.getErrorStream();
            String text = "";
            if (input != null) {
                try (InputStream stream = input; ByteArrayOutputStream bytes = new ByteArrayOutputStream()) {
                    byte[] buffer = new byte[8192]; int count;
                    while ((count = stream.read(buffer)) != -1) {
                        if (bytes.size() + count > 1024 * 1024) throw new IOException("Account response is too large.");
                        bytes.write(buffer, 0, count);
                    }
                    text = bytes.toString(StandardCharsets.UTF_8.name());
                }
            }
            JSONObject value;
            try { value = text.isEmpty() ? new JSONObject() : new JSONObject(text); }
            catch (Exception e) { if (status >= 200 && status < 300) throw e; else value = new JSONObject(); }
            if (status < 200 || status >= 300) throw new Failure(status, value.optString("error_code", value.optString("error", "")));
            return value;
        } finally { connection.disconnect(); }
    }
}
