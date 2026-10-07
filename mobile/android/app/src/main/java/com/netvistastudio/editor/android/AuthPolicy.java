package com.netvistastudio.editor.android;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/** Pure policy: transient failures never erase a valid user's saved work/session. */
public final class AuthPolicy {
    public static final long CHECK_INTERVAL_MS = 25L * 60 * 1000;
    private static final Set<String> REVOKED = new HashSet<>(Arrays.asList(
            "user_not_found", "user_banned", "session_not_found", "session_expired",
            "refresh_token_not_found", "refresh_token_already_used", "bad_jwt"));
    private AuthPolicy() {}
    public static boolean rejectsSession(int status, String code) {
        return status == 401 || status == 403 || REVOKED.contains(code);
    }
    public static boolean due(long nowMs, long lastAttemptMs, long retryAtMs, long expiresAtSeconds) {
        return nowMs >= retryAtMs && (lastAttemptMs == 0
                || nowMs - lastAttemptMs >= CHECK_INTERVAL_MS || expiresAtSeconds * 1000 <= nowMs + 60000);
    }
}
