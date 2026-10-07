package com.netvistastudio.editor.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.res.Configuration;
import android.database.Cursor;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.effect.Presentation;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;
import androidx.media3.transformer.Composition;
import androidx.media3.transformer.ExportException;
import androidx.media3.transformer.ExportResult;
import androidx.media3.transformer.ProgressHolder;
import androidx.media3.transformer.Transformer;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

/** A native local editor, not a website wrapper or a remote desktop companion. */
@UnstableApi
public final class MainActivity extends Activity {
    private static final int IMPORT_VIDEO = 100, OPEN_PROJECT = 101, SAVE_PROJECT = 102, SAVE_MOVIE = 103;
    private static final int BACKGROUND = Color.rgb(12, 14, 18), PANEL = Color.rgb(23, 27, 33);
    private static final int TEXT = Color.rgb(240, 241, 244), MUTED = Color.rgb(155, 165, 181), GOLD = Color.rgb(198, 169, 120);
    private static final Object DRAFT_LOCK = new Object();
    private static final AtomicLong ACTIVE_ACTIVITY = new AtomicLong();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final List<Button> editActions = new ArrayList<>();
    private StudioAccount account;
    private ProjectFiles files;
    private StudioProject project = new StudioProject();
    private ExoPlayer player;
    private Transformer transformer;
    private File renderingFile, completedMovie;
    private LinearLayout root, timeline, inspector;
    private TextView status, summary, accountStatus, loginStatus;
    private Button signInButton, cancelExport;
    private EditText inField, outField;
    private PlayerView playerView;
    private ProgressBar progress;
    private int selected = -1;
    private boolean editorVisible, operationBusy, foreground;
    private volatile boolean destroyed;
    private long activityGeneration, operationGeneration;
    private boolean draftReady;
    private StudioProject pendingSave;
    private final StudioAccount.Listener accountListener = this::accountChanged;
    private final Runnable accountTimer = new Runnable() {
        @Override public void run() { if (foreground && liveUi()) { account.checkAsync(false); main.postDelayed(this, 30000); } }
    };
    private final Runnable exportTimer = new Runnable() {
        @Override public void run() {
            if (!liveUi() || transformer == null || renderingFile == null) return;
            ProgressHolder holder = new ProgressHolder();
            if (transformer.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                progress.setIndeterminate(false); progress.setProgress(holder.progress);
                status.setText("Rendering MP4 · " + holder.progress + "% · keep the app open");
            }
            main.postDelayed(this, 500);
        }
    };

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        synchronized (DRAFT_LOCK) { activityGeneration = ACTIVE_ACTIVITY.incrementAndGet(); }
        try { files = new ProjectFiles(this); }
        catch (IOException e) { new AlertDialog.Builder(this).setMessage(e.getMessage()).setPositiveButton("Close", (d, w) -> finish()).show(); return; }
        if (saved != null) {
            String movie = saved.getString("rendered_movie");
            if (movie != null && movie.matches("netvista-export-[0-9a-f-]+\\.mp4")) {
                File restored = new File(getCacheDir(), movie); if (restored.isFile()) completedMovie = restored;
            }
        }
        account = StudioAccount.get(this); showLogin(); account.addListener(accountListener);
        AccountCheckJob.schedule(this);
        io.execute(() -> {
            try {
                StudioProject restored;
                synchronized (DRAFT_LOCK) { restored = files.loadDraft(); }
                postUi(() -> { project = restored; draftReady = true; selected = project.clips.isEmpty() ? -1 : 0; updateEnabled(); if (editorVisible) refreshTimeline(true); });
            } catch (Exception e) { postUi(() -> { draftReady = true; updateEnabled(); message("Previous edit could not be restored. Your saved project files are untouched."); }); }
        });
    }

    private void accountChanged(StudioAccount.Snapshot state) {
        if (!liveUi()) return;
        if (state.canEdit) {
            if (!editorVisible) showEditor();
            accountStatus.setText((state.email.isEmpty() ? "NetVista account" : state.email) + "\n" + state.status);
        } else {
            if (editorVisible) {
                if (transformer != null || renderingFile != null) cancelRendering("Account unavailable. Export cancelled; your project remains saved locally.");
                autosave(); showLogin();
            }
            if (loginStatus != null) loginStatus.setText(state.status);
            if (signInButton != null) signInButton.setEnabled(!state.busy);
        }
    }

    private LinearLayout screen() {
        editActions.clear();
        root = column(); root.setPadding(dp(16), dp(12), dp(16), dp(12)); root.setBackgroundColor(BACKGROUND);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(dp(16) + insets.getSystemWindowInsetLeft(), dp(12) + insets.getSystemWindowInsetTop(),
                    dp(16) + insets.getSystemWindowInsetRight(), dp(12) + insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(root); root.requestApplyInsets(); return root;
    }
    private void header(LinearLayout parent) {
        LinearLayout row = row(); row.setGravity(Gravity.CENTER_VERTICAL);
        ImageView logo = new ImageView(this); logo.setImageResource(R.drawable.netvista_logo);
        logo.setContentDescription("NetVista Studio logo"); logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        row.addView(logo, new LinearLayout.LayoutParams(dp(52), dp(52)));
        LinearLayout words = column(); words.setPadding(dp(12), 0, 0, 0);
        words.addView(label("NETVISTA STUDIO", 18, TEXT, true));
        words.addView(label("ANDROID · BETA 7 · FIRST MOBILE EDITION", 10, GOLD, true));
        row.addView(words, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        Button info = button("About", this::about, false); row.addView(info); parent.addView(row);
    }
    private void showLogin() {
        editorVisible = false;
        if (player != null) { player.release(); player = null; }
        LinearLayout container = screen(); header(container);
        ScrollView scroll = new ScrollView(this); LinearLayout form = column(); form.setPadding(0, dp(32), 0, dp(24)); scroll.addView(form);
        form.addView(label("Your next cut starts here.", 28, TEXT, true));
        form.addView(label("Sign in with your NetVista account. Video editing and exports run on this device—no Mac or website required.", 15, MUTED, false));
        EditText email = field("Email address", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        EditText password = field("Password", InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        password.setSaveEnabled(false); password.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        form.addView(email); form.addView(password);
        CheckBox remember = new CheckBox(this); remember.setText("Remember securely on this device"); remember.setTextColor(TEXT); remember.setChecked(true); form.addView(remember);
        signInButton = button("Sign in", () -> {
            String value = password.getText().toString(); password.getText().clear();
            account.signIn(email.getText().toString(), value, remember.isChecked());
        }, false); form.addView(signInButton);
        form.addView(button("Create or manage account", () -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(StudioAccount.ACCOUNT_URL))), false));
        loginStatus = label("Checking saved sign-in…", 13, MUTED, false); form.addView(loginStatus);
        form.addView(label("First mobile beta: import videos, preview your sequence, trim and reorder clips, save a self-contained project, and export MP4. Desktop colour, photo, 3D, Game Maker and mods are not included.", 12, MUTED, false));
        container.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
    }
    private void showEditor() {
        editorVisible = true; loginStatus = null; signInButton = null;
        LinearLayout container = screen(); header(container);
        ScrollView scroll = new ScrollView(this); LinearLayout editor = column(); scroll.setFillViewport(true); scroll.addView(editor);
        accountStatus = label("Account verified", 11, MUTED, false); editor.addView(accountStatus);
        LinearLayout tools = row(); tools.addView(weighted(button("＋ Import", this::pickVideos, true)));
        tools.addView(weighted(button("Save", this::pickSaveProject, true))); tools.addView(weighted(button("Open", this::pickOpenProject, true))); editor.addView(tools);
        LinearLayout projectTools = row(); projectTools.addView(weighted(button("Project", this::projectMenu, true)));
        projectTools.addView(weighted(button("Preview ▶", () -> preview(true), true)));
        projectTools.addView(weighted(button("Export MP4", this::export, true))); editor.addView(projectTools);
        player = new ExoPlayer.Builder(this).build();
        playerView = new PlayerView(this); playerView.setPlayer(player); playerView.setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FIT);
        playerView.setBackgroundColor(Color.BLACK); playerView.setShowNextButton(true); playerView.setShowPreviousButton(true);
        editor.addView(playerView, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, previewHeight()));
        player.addListener(new Player.Listener() {
            @Override public void onMediaItemTransition(MediaItem mediaItem, int reason) {
                if (liveUi() && mediaItem != null) {
                    for (int i = 0; i < project.clips.size(); i++) if (project.clips.get(i).id.equals(mediaItem.mediaId) && i != selected) {
                        selected = i; refreshTimeline(false); break;
                    }
                }
            }
            @Override public void onPlayerError(PlaybackException error) { message("Preview unavailable for this video/codec. Try a standard H.264 MP4. " + error.getErrorCodeName()); }
        });
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); progress.setMax(100); progress.setVisibility(View.GONE); editor.addView(progress);
        cancelExport = button("Cancel export", () -> cancelRendering("Export cancelled. Your source videos and project are untouched."), false);
        cancelExport.setVisibility(View.GONE); editor.addView(cancelExport);
        status = label("Import local videos to start editing.", 12, GOLD, false); editor.addView(status);
        summary = label("TIMELINE", 12, TEXT, true); editor.addView(summary);
        timeline = column(); editor.addView(timeline);
        inspector = column(); editor.addView(inspector);
        editor.addView(label("Cuts-only mobile timeline · MP4 H.264/AAC at 30 fps · selected canvas fits mixed source orientations", 11, MUTED, false));
        container.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        refreshTimeline(true); updateEnabled();
    }

    private void refreshTimeline(boolean updatePreview) {
        if (!liveUi() || !editorVisible || timeline == null) return;
        selected = project.clips.isEmpty() ? -1 : Math.max(0, Math.min(selected, project.clips.size() - 1));
        summary.setText(project.title + " · " + project.clips.size() + " clips · " + time(project.durationMs())
                + " · " + project.width + "×" + project.height);
        timeline.removeAllViews(); inspector.removeAllViews();
        long start = 0;
        for (int i = 0; i < project.clips.size(); i++) {
            StudioProject.Clip clip = project.clips.get(i); final int index = i;
            LinearLayout item = column(); item.setPadding(dp(12), dp(10), dp(12), dp(10));
            GradientDrawable background = new GradientDrawable(); background.setColor(i == selected ? Color.rgb(44, 41, 34) : PANEL);
            background.setCornerRadius(dp(8)); background.setStroke(dp(1), i == selected ? GOLD : PANEL); item.setBackground(background);
            TextView name = label(String.format(Locale.ROOT, "%02d  %s", i + 1, clip.name), 14, TEXT, true);
            name.setMaxLines(2); item.addView(name); item.addView(label(time(start) + " → " + time(start + clip.lengthMs())
                    + "   |   source " + time(clip.inMs) + "–" + time(clip.outMs), 11, MUTED, false));
            item.setOnClickListener(v -> { if (!operationBusy) { selected = index; refreshTimeline(false); preview(false); } });
            LinearLayout reorder = row(); Button up = button("↑ Earlier", () -> move(index, -1), false);
            Button down = button("↓ Later", () -> move(index, 1), false);
            up.setEnabled(!operationBusy && index > 0); down.setEnabled(!operationBusy && index + 1 < project.clips.size());
            reorder.addView(weighted(up)); reorder.addView(weighted(down));
            Button remove = button("Remove", () -> { if (!operationBusy) { project.clips.remove(index); autosave(); refreshTimeline(true); } }, false);
            remove.setEnabled(!operationBusy); reorder.addView(weighted(remove)); item.addView(reorder);
            LinearLayout.LayoutParams bounds = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            bounds.topMargin = dp(6); timeline.addView(item, bounds); start += clip.lengthMs();
        }
        if (selected >= 0) {
            StudioProject.Clip clip = project.clips.get(selected);
            inspector.addView(label("TRIM SELECTED CLIP · seconds", 12, GOLD, true));
            LinearLayout values = row(); inField = field("In (seconds)", InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
            outField = field("Out (seconds)", InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
            inField.setText(seconds(clip.inMs)); outField.setText(seconds(clip.outMs));
            values.addView(weighted(inField)); values.addView(weighted(outField)); inspector.addView(values);
            LinearLayout marks = row(); marks.addView(weighted(button("Set In here", () -> mark(true), false)));
            marks.addView(weighted(button("Set Out here", () -> mark(false), false)));
            marks.addView(weighted(button("Apply trim", this::applyTrim, false))); inspector.addView(marks);
            inField.setEnabled(!operationBusy); outField.setEnabled(!operationBusy);
        } else timeline.addView(label("No clips yet. Import one or several videos from Files.", 15, MUTED, false));
        if (updatePreview) preview(false);
    }
    private void preview(boolean play) {
        if (!liveUi() || operationBusy || player == null) return;
        try {
            if (project.clips.isEmpty()) { player.clearMediaItems(); return; }
            List<MediaItem> items = MobileExport.previewItems(project, files);
            player.setVideoEffects(java.util.Collections.singletonList(Presentation.createForWidthAndHeight(
                    project.width, project.height, Presentation.LAYOUT_SCALE_TO_FIT)));
            player.setMediaItems(items, Math.max(0, selected), 0); player.prepare(); player.setPlayWhenReady(play);
        } catch (Exception e) { message(e.getMessage()); }
    }
    private void move(int index, int direction) {
        if (operationBusy) return;
        int target = index + direction;
        if (target < 0 || target >= project.clips.size()) return;
        project.move(index, target); selected = target; autosave(); refreshTimeline(true);
    }
    private void mark(boolean in) {
        if (operationBusy || selected < 0 || player == null || player.getCurrentMediaItem() == null) return;
        StudioProject.Clip clip = project.clips.get(selected);
        if (!clip.id.equals(player.getCurrentMediaItem().mediaId)) { message("Preview the selected clip first."); return; }
        long position = Math.min(clip.outMs, clip.inMs + player.getCurrentPosition());
        (in ? inField : outField).setText(seconds(position));
    }
    private void applyTrim() {
        if (operationBusy || selected < 0) return;
        try {
            double in = Double.parseDouble(inField.getText().toString()), out = Double.parseDouble(outField.getText().toString());
            if (!Double.isFinite(in) || !Double.isFinite(out) || in < 0 || out > project.clips.get(selected).durationMs / 1000.0) throw new IllegalArgumentException("Trim times must be inside the source video.");
            project.clips.get(selected).trim(Math.round(in * 1000), Math.round(out * 1000));
            autosave(); refreshTimeline(true); message("Trim applied to preview and export.");
        } catch (Exception e) { message("Invalid trim: Out must be after In, within the source duration."); }
    }

    private void pickVideos() {
        if (operationBusy || project.clips.size() >= StudioProject.MAX_CLIPS) return;
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.setType("video/*");
        intent.addCategory(Intent.CATEGORY_OPENABLE); intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION); startActivityForResult(intent, IMPORT_VIDEO);
    }
    private void pickOpenProject() {
        if (operationBusy) return;
        new AlertDialog.Builder(this).setTitle("Open a mobile project?")
                .setMessage("Your current edit is autosaved privately. Save a self-contained project first if you want to keep both edits.")
                .setNegativeButton("Cancel", null).setPositiveButton("Open", (d, w) -> {
                    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.setType("*/*"); intent.addCategory(Intent.CATEGORY_OPENABLE);
                    startActivityForResult(intent, OPEN_PROJECT);
                }).show();
    }
    private void pickSaveProject() {
        if (operationBusy) return;
        pendingSave = project.copy(); createDocument("application/octet-stream", filename(project.title) + ".netvistamobile", SAVE_PROJECT);
    }
    private void createDocument(String type, String name, int request) {
        if (!liveUi() || !foreground) return;
        Intent intent = new Intent(Intent.ACTION_CREATE_DOCUMENT); intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType(type); intent.putExtra(Intent.EXTRA_TITLE, name); startActivityForResult(intent, request);
    }
    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (!liveUi() || account == null || io.isShutdown()) return;
        if (result != RESULT_OK || data == null) { if (request == SAVE_PROJECT) pendingSave = null; return; }
        if (!account.state().canEdit) { message("Sign in again to continue. Your project is safe."); return; }
        if (request == IMPORT_VIDEO) {
            List<Uri> uris = new ArrayList<>();
            if (data.getClipData() != null) for (int i = 0; i < data.getClipData().getItemCount(); i++) uris.add(data.getClipData().getItemAt(i).getUri());
            else if (data.getData() != null) uris.add(data.getData());
            importVideos(uris); return;
        }
        Uri destination = data.getData(); if (destination == null) return;
        if (request == OPEN_PROJECT) loadProject(destination);
        else if (request == SAVE_PROJECT && pendingSave != null) {
            StudioProject value = pendingSave; pendingSave = null;
            setBusy(true, "Saving project with original videos…");
            long ticket = ++operationGeneration;
            io.execute(() -> {
                try (OutputStream output = getContentResolver().openOutputStream(destination, "w")) {
                    if (output == null) throw new IOException("Project destination is unavailable."); files.saveArchive(value, output);
                } catch (Exception e) {
                    deleteIncomplete(destination); postResult(ticket, () -> setBusy(false, "Project save failed: " + e.getMessage())); return;
                }
                postResult(ticket, () -> setBusy(false, "Self-contained project saved. All imported videos are included."));
            });
        } else if (request == SAVE_MOVIE && completedMovie != null) saveMovie(destination);
    }
    private void importVideos(List<Uri> uris) {
        setBusy(true, "Copying selected videos into private storage…");
        long ticket = ++operationGeneration;
        StudioProject target = project.copy();
        int available = StudioProject.MAX_CLIPS - project.clips.size();
        io.execute(() -> {
            List<StudioProject.Clip> imported = new ArrayList<>(); List<String> failures = new ArrayList<>();
            for (Uri uri : uris.subList(0, Math.min(available, uris.size()))) {
                String id = UUID.randomUUID().toString(); File copy = null;
                try {
                    String name = displayName(uri); copy = files.importVideo(uri, id); long duration = videoDuration(copy);
                    imported.add(new StudioProject.Clip(id, "media/" + id + ".video", name, duration, 0, duration));
                } catch (Exception e) { if (copy != null) copy.delete(); failures.add("One video was unreadable, unsupported or exceeded 4 GiB."); }
            }
            target.clips.addAll(imported);
            String saveWarning = "";
            try {
                if (!saveDraftIfCurrent(target)) { removePrivateCopies(imported); return; }
            } catch (Exception e) {
                if (destroyed || ACTIVE_ACTIVITY.get() != activityGeneration) { removePrivateCopies(imported); return; }
                saveWarning = " Private autosave failed—use Save to keep a project backup.";
            }
            String result = imported.size() + " videos imported." + (failures.isEmpty() ? "" : " " + failures.size() + " could not be imported.") + saveWarning;
            postResult(ticket, () -> {
                project = target; selected = project.clips.isEmpty() ? -1 : project.clips.size() - imported.size();
                setBusy(false, result); refreshTimeline(true);
            });
        });
    }
    private void loadProject(Uri source) {
        setBusy(true, "Loading self-contained project…");
        long ticket = ++operationGeneration;
        io.execute(() -> {
            StudioProject imported = null;
            try {
                StudioProject loaded;
                try (InputStream input = getContentResolver().openInputStream(source)) {
                    if (input == null) throw new IOException("Project cannot be read.");
                    loaded = files.loadArchive(input); imported = loaded;
                }
                // Validate the real video and duration instead of trusting archive metadata.
                for (int i = 0; i < loaded.clips.size(); i++) {
                    StudioProject.Clip clip = loaded.clips.get(i); long actual = videoDuration(files.mediaFile(clip));
                    loaded.clips.set(i, new StudioProject.Clip(clip.id, clip.uri, clip.name, actual, clip.inMs, clip.outMs));
                }
                if (!saveDraftIfCurrent(loaded)) { removePrivateCopies(loaded.clips); return; }
                postResult(ticket, () -> { project = loaded; selected = loaded.clips.isEmpty() ? -1 : 0; setBusy(false, "Project loaded with its own video copies."); refreshTimeline(true); });
            } catch (Exception e) {
                // These are new private copies created by this failed import, not
                // originals, current-project media, or files from the provider.
                if (imported != null) removePrivateCopies(imported.clips);
                postResult(ticket, () -> setBusy(false, "Open failed: " + e.getMessage() + " Your current edit is unchanged."));
            }
        });
    }
    private long videoDuration(File file) throws Exception {
        MediaMetadataRetriever metadata = new MediaMetadataRetriever();
        try {
            metadata.setDataSource(file.getAbsolutePath());
            if (!"yes".equals(metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO))) throw new IOException("Not a video.");
            String duration = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            if (duration == null) throw new IOException("Video duration is unavailable.");
            long value = Long.parseLong(duration); if (value < 1) throw new IOException("Video is empty."); return value;
        } finally { metadata.release(); }
    }
    private String displayName(Uri uri) {
        try (Cursor cursor = getContentResolver().query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) { String name = cursor.getString(0); if (name != null) return name.substring(0, Math.min(name.length(), 512)); }
        } catch (Exception ignored) { /* use a safe fallback, not a path */ }
        return "Imported video";
    }

    private void export() {
        if (operationBusy || project.clips.isEmpty()) { message("Import a video before exporting."); return; }
        if (completedMovie != null && completedMovie.isFile()) {
            new AlertDialog.Builder(this).setTitle("Rendered movie waiting to be saved")
                    .setMessage("Save the existing render first, or discard it and render your current edit.")
                    .setPositiveButton("Save render", (d, w) -> createDocument("video/mp4", filename(project.title) + ".mp4", SAVE_MOVIE))
                    .setNegativeButton("Render again", (d, w) -> { completedMovie.delete(); completedMovie = null; export(); }).show(); return;
        }
        try {
            Composition composition = MobileExport.composition(project.copy(), files);
            renderingFile = File.createTempFile("netvista-export-", ".mp4", getCacheDir());
            // Transformer expects to create its own output, never an existing user movie.
            if (!renderingFile.delete()) throw new IOException("Export staging is unavailable.");
            player.stop(); setBusy(true, "Rendering MP4 · keep the app open"); cancelExport.setVisibility(View.VISIBLE);
            long ticket = ++operationGeneration;
            File outputFile = renderingFile;
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            transformer = MobileExport.transformer(this, new Transformer.Listener() {
                @Override public void onCompleted(Composition composition, ExportResult result) {
                    if (!liveUi() || ticket != operationGeneration || renderingFile != outputFile) { outputFile.delete(); return; }
                    completedMovie = renderingFile; renderingFile = null; transformer = null;
                    finishRender(); setBusy(false, "Render complete. Choose where to save your MP4.");
                    createDocument("video/mp4", filename(project.title) + ".mp4", SAVE_MOVIE);
                }
                @Override public void onError(Composition composition, ExportResult result, ExportException error) {
                    if (!liveUi() || ticket != operationGeneration || renderingFile != outputFile) { outputFile.delete(); return; }
                    cancelRendering("Export failed: " + error.getErrorCodeName() + ". Device codecs may not support this source/size. Source videos are unchanged.");
                }
            });
            transformer.start(composition, renderingFile.getAbsolutePath()); main.post(exportTimer);
        } catch (Exception e) { cancelRendering("Export could not start: " + e.getMessage()); }
    }
    private void saveMovie(Uri destination) {
        File source = completedMovie; setBusy(true, "Saving rendered MP4…");
        long ticket = ++operationGeneration;
        io.execute(() -> {
            try (InputStream input = new FileInputStream(source); OutputStream output = getContentResolver().openOutputStream(destination, "w")) {
                if (output == null) throw new IOException("Movie destination is unavailable.");
                ProjectFiles.copy(input, output, Long.MAX_VALUE);
            } catch (Exception e) {
                deleteIncomplete(destination); postResult(ticket, () -> setBusy(false, "Movie save failed; the render is retained for retry. " + e.getMessage())); return;
            }
            source.delete();
            postResult(ticket, () -> { completedMovie = null; setBusy(false, "MP4 exported successfully. Open it from your chosen Files location."); });
        });
    }
    private void cancelRendering(String message) {
        if (transformer != null || renderingFile != null) operationGeneration++;
        if (transformer != null) { transformer.cancel(); transformer = null; }
        if (renderingFile != null) { renderingFile.delete(); renderingFile = null; }
        finishRender(); setBusy(false, message);
    }
    private void finishRender() {
        main.removeCallbacks(exportTimer); getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (cancelExport != null) cancelExport.setVisibility(View.GONE);
    }
    private void deleteIncomplete(Uri uri) {
        try { DocumentsContract.deleteDocument(getContentResolver(), uri); }
        catch (Exception ignored) { postUi(() -> message("Your Files provider could not remove the incomplete output. Remove that incomplete file manually.")); }
    }
    private void autosave() {
        if (files == null || !draftReady || operationBusy || destroyed || io.isShutdown()) return;
        StudioProject value = project.copy(); io.execute(() -> {
            try { saveDraftIfCurrent(value); }
            catch (Exception e) { postUi(() -> message("Private autosave failed. Use Save to keep a project backup.")); }
        });
    }

    private boolean saveDraftIfCurrent(StudioProject value) throws Exception {
        synchronized (DRAFT_LOCK) {
            if (ACTIVE_ACTIVITY.get() != activityGeneration) return false;
            files.saveDraft(value); return true;
        }
    }
    private void removePrivateCopies(List<StudioProject.Clip> clips) {
        for (StudioProject.Clip clip : clips) {
            try { files.mediaFile(clip).delete(); } catch (IOException ignored) { /* invalid IDs never resolve paths */ }
        }
    }
    private boolean liveUi() { return !destroyed && !isFinishing() && !isDestroyed() && ACTIVE_ACTIVITY.get() == activityGeneration; }
    private void postUi(Runnable result) { main.post(() -> { if (liveUi()) result.run(); }); }
    private void postResult(long ticket, Runnable result) { postUi(() -> { if (ticket == operationGeneration) result.run(); }); }
    private void projectMenu() {
        if (operationBusy) return;
        new AlertDialog.Builder(this).setTitle("Project")
                .setItems(new String[]{"Rename edit", "Export canvas", "New edit", "Account: check now", "Sign out"}, (dialog, which) -> {
                    if (which == 0) {
                        EditText title = field("Project name", InputType.TYPE_CLASS_TEXT); title.setText(project.title);
                        new AlertDialog.Builder(this).setTitle("Rename edit").setView(title).setNegativeButton("Cancel", null)
                                .setPositiveButton("Rename", (d, w) -> { String text = title.getText().toString().trim(); project.title = text.isEmpty() ? "Untitled edit" : text.substring(0, Math.min(text.length(), 200)); autosave(); refreshTimeline(false); }).show();
                    } else if (which == 1) {
                        new AlertDialog.Builder(this).setTitle("Export canvas · 30 fps")
                                .setItems(new String[]{"1080p landscape · 1920×1080", "720p landscape · 1280×720", "1080p portrait · 1080×1920"}, (d, size) -> {
                                    project.width = size == 1 ? 1280 : size == 2 ? 1080 : 1920;
                                    project.height = size == 1 ? 720 : size == 2 ? 1920 : 1080;
                                    autosave(); refreshTimeline(true);
                                }).show();
                    } else if (which == 2) {
                        new AlertDialog.Builder(this).setTitle("Start a new edit?").setMessage("Save your current edit as a self-contained project first. Imported video copies remain in app storage.")
                                .setNegativeButton("Cancel", null).setPositiveButton("New edit", (d, w) -> { project = new StudioProject(); selected = -1; autosave(); refreshTimeline(true); }).show();
                    } else if (which == 3) account.checkAsync(true);
                    else new AlertDialog.Builder(this).setTitle("Sign out?").setMessage("Your edit is autosaved privately. You can reopen it after signing in.")
                                .setNegativeButton("Cancel", null).setPositiveButton("Sign out", (d, w) -> { autosave(); account.signOut(); }).show();
                }).show();
    }
    private void about() {
        String text = "NetVista Studio 1.4.0 · Beta 7\nFirst standalone Android mobile edition\n\nNative local video editing: import, sequence preview, trims, clip order, portable projects and H.264/AAC MP4 export.\n\nThis is not the full desktop editor. There are no transitions, layered audio/video tracks, colour grading, effects, photo/3D/Game Maker, mods or desktop project compatibility. Projects embed original videos; keep backups before uninstalling. Android may defer background account checks. Exports require the app to remain foreground.\n\nOpen-source notices:\n";
        try (InputStream input = getAssets().open("THIRD_PARTY_NOTICES.txt")) {
            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream(); ProjectFiles.copy(input, output, 128 * 1024);
            text += output.toString(StandardCharsets.UTF_8.name());
        } catch (IOException e) { text += "AndroidX Media3, AndroidX and Guava: Apache License 2.0. https://www.apache.org/licenses/LICENSE-2.0"; }
        TextView body = label(text, 13, TEXT, false); body.setPadding(dp(16), dp(8), dp(16), dp(8));
        ScrollView scroll = new ScrollView(this); scroll.addView(body);
        new AlertDialog.Builder(this).setTitle("About & licenses").setView(scroll).setPositiveButton("Close", null).show();
    }
    private void setBusy(boolean busy, String message) {
        if (!liveUi()) return;
        operationBusy = busy; updateEnabled(); message(message);
        if (progress != null) { progress.setVisibility(busy ? View.VISIBLE : View.GONE); progress.setIndeterminate(true); }
        if (editorVisible) refreshTimeline(false);
    }
    private void updateEnabled() { for (Button action : editActions) action.setEnabled(!operationBusy && draftReady); }
    private void message(String value) { if (!liveUi()) return; if (status != null && editorVisible) status.setText(value == null ? "Operation unavailable." : value); }
    private int previewHeight() { return dp(getResources().getConfiguration().smallestScreenWidthDp >= 600 ? 320 : 220); }
    @Override public void onConfigurationChanged(Configuration configuration) { super.onConfigurationChanged(configuration); if (playerView != null) { ViewGroup.LayoutParams params = playerView.getLayoutParams(); params.height = previewHeight(); playerView.setLayoutParams(params); } }
    @Override protected void onResume() { super.onResume(); foreground = true; if (account != null) { account.checkAsync(true); main.removeCallbacks(accountTimer); main.post(accountTimer); } }
    @Override protected void onStop() { foreground = false; main.removeCallbacks(accountTimer); if (player != null) player.pause(); if (renderingFile != null) cancelRendering("Export cancelled when the app left the foreground. Keep the app open while rendering."); if (editorVisible) autosave(); super.onStop(); }
    @Override protected void onSaveInstanceState(Bundle saved) { if (completedMovie != null) saved.putString("rendered_movie", completedMovie.getName()); super.onSaveInstanceState(saved); }
    @Override protected void onDestroy() {
        destroyed = true; operationGeneration++; editorVisible = false;
        if (account != null) account.removeListener(accountListener);
        main.removeCallbacksAndMessages(null);
        if (transformer != null) { transformer.cancel(); transformer = null; }
        if (renderingFile != null) { renderingFile.delete(); renderingFile = null; }
        if (player != null) { player.release(); player = null; }
        playerView = null;
        // shutdown(), not shutdownNow(): pending document writes and private draft
        // commits may finish, but all of their screen callbacks are lifecycle guarded.
        io.shutdown(); super.onDestroy();
    }
    private LinearLayout column() { LinearLayout value = new LinearLayout(this); value.setOrientation(LinearLayout.VERTICAL); return value; }
    private LinearLayout row() { LinearLayout value = new LinearLayout(this); value.setOrientation(LinearLayout.HORIZONTAL); return value; }
    private <T extends View> T weighted(T view) { view.setLayoutParams(new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1)); return view; }
    private TextView label(String value, int size, int color, boolean bold) { TextView text = new TextView(this); text.setText(value); text.setTextSize(size); text.setTextColor(color); text.setPadding(0, dp(8), 0, dp(8)); if (bold) text.setTypeface(Typeface.DEFAULT, Typeface.BOLD); return text; }
    private Button button(String value, Runnable action, boolean editing) { Button button = new Button(this); button.setText(value); button.setAllCaps(false); button.setTextSize(12); button.setTextColor(TEXT); button.setMinWidth(0); button.setMinimumWidth(0); button.setMinHeight(dp(48)); button.setPadding(dp(6), 0, dp(6), 0); button.setOnClickListener(v -> action.run()); if (editing) editActions.add(button); return button; }
    private EditText field(String hint, int type) { EditText field = new EditText(this); field.setHint(hint); field.setTextColor(TEXT); field.setHintTextColor(MUTED); field.setInputType(type); field.setSingleLine(true); field.setTextSize(15); field.setMinimumHeight(dp(48)); return field; }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private static String filename(String name) { String value = name.replaceAll("[^A-Za-z0-9._ -]", "_").trim(); return value.isEmpty() ? "NetVista edit" : value.substring(0, Math.min(value.length(), 80)); }
    private static String seconds(long milliseconds) { return String.format(Locale.ROOT, "%.3f", milliseconds / 1000.0); }
    private static String time(long milliseconds) { return String.format(Locale.ROOT, "%02d:%02d.%03d", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000); }
}
