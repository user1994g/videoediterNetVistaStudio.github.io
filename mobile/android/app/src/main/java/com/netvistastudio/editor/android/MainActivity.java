package com.netvistastudio.editor.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.res.Configuration;
import android.content.res.ColorStateList;
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
import android.text.TextUtils;
import android.util.Log;
import android.view.inputmethod.EditorInfo;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import androidx.annotation.OptIn;
import androidx.media3.common.PlaybackException;
import androidx.media3.common.Player;
import androidx.media3.common.util.ExperimentalApi;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.ui.AspectRatioFrameLayout;
import androidx.media3.ui.PlayerView;
import androidx.media3.transformer.Composition;
import androidx.media3.transformer.CompositionPlayer;
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
import java.util.ArrayDeque;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

/** A native local editor, not a website wrapper or a remote desktop companion. */
@UnstableApi
@OptIn(markerClass = ExperimentalApi.class)
public final class MainActivity extends Activity {
    private static final int IMPORT_VIDEO = 100, OPEN_PROJECT = 101, SAVE_PROJECT = 102, SAVE_MOVIE = 103;
    private static final int BACKGROUND = Color.rgb(23, 25, 30), PANEL = Color.rgb(32, 35, 42);
    private static final int TOP = Color.rgb(17, 19, 23), WORKSPACE = Color.rgb(24, 27, 33), CONTROL = Color.rgb(36, 42, 51), CARD = Color.rgb(32, 40, 51);
    private static final int TEXT = Color.WHITE, MUTED = Color.rgb(157, 166, 181), ACCENT = Color.rgb(240, 91, 94), SEPARATOR = Color.rgb(54, 59, 70);
    private static final Object DRAFT_LOCK = new Object();
    private static final AtomicLong ACTIVE_ACTIVITY = new AtomicLong();
    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService io = Executors.newSingleThreadExecutor();
    private final List<Button> editActions = new ArrayList<>();
    private StudioAccount account;
    private ProjectFiles files;
    private StudioProject project = new StudioProject();
    private CompositionPlayer player;
    private Transformer transformer;
    private File renderingFile, completedMovie;
    private LinearLayout root, mediaList, inspector, inspectorPanel, mediaPanel, monitorPanel, compactDrawer;
    private StudioTimelineView timeline;
    private TextView projectTitle, timecode, mediaSummary;
    private Button playButton, undoButton, redoButton;
    private TextView status, summary, accountStatus, loginStatus;
    private Button signInButton, cancelExport;
    private EditText inField, outField;
    private PlayerView playerView;
    private AlertDialog compactDialog;
    private ProgressBar progress;
    private int selected = -1;
    private boolean editorVisible, homeVisible, operationBusy, foreground, wideLayout, pendingLayoutRebuild;
    private volatile boolean destroyed;
    private long activityGeneration, operationGeneration;
    private boolean draftReady;
    private int inspectorTab, compactPanel = 1;
    private String selectedSource;
    private long playheadMs;
    private boolean previewPending, previewPlayWhenReady;
    private final ArrayDeque<EditState> undo = new ArrayDeque<>(), redo = new ArrayDeque<>();
    private static final class EditState {
        final StudioProject project; final int selected; final long playhead;
        EditState(StudioProject project, int selected, long playhead) { this.project = project.copy(); this.selected = selected; this.playhead = playhead; }
    }
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
    private final Runnable playheadTimer = new Runnable() {
        @Override public void run() {
            if (!liveUi() || !editorVisible || !foreground) return;
            if (player != null && !project.clips.isEmpty()) {
                if (player.isPlaying()) {
                    // Paused seeks and composition updates resolve asynchronously.
                    // Reading an old player position while paused must never replace
                    // the user's explicit scrub/edit point before the seek settles.
                    playheadMs = Math.max(0, Math.min(project.durationMs(), player.getCurrentPosition()));
                    int index = clipAt(playheadMs);
                    if (index != selected) { selected = index; refreshInspector(); refreshPool(); timeline.setProject(project, selected); }
                }
                updatePlayhead(player.isPlaying());
            }
            main.postDelayed(this, 50);
        }
    };
    private final Runnable effectsPreview = () -> applyPreview(previewPlayWhenReady);

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
                postUi(() -> { project = restored; draftReady = true; selected = project.clips.isEmpty() ? -1 : 0; updateEnabled(); if (editorVisible) refreshTimeline(true); else if (homeVisible) showHome(); });
            } catch (Exception e) { postUi(() -> { draftReady = true; updateEnabled(); message("Previous edit could not be restored. Your saved project files are untouched."); }); }
        });
    }

    private void accountChanged(StudioAccount.Snapshot state) {
        if (!liveUi()) return;
        if (state.canEdit) {
            if (!editorVisible && !homeVisible) showHome();
            if (accountStatus != null) { accountStatus.setText(state.email.isEmpty() ? "Account verified" : state.email); accountStatus.setContentDescription(state.status); }
        } else {
            if (editorVisible || homeVisible) {
                if (transformer != null || renderingFile != null) cancelRendering("Account unavailable. Export cancelled; your project remains saved locally.");
                autosave(); showLogin();
            }
            if (loginStatus != null) loginStatus.setText(state.status);
            if (signInButton != null) signInButton.setEnabled(!state.busy);
        }
    }

    private LinearLayout screen() {
        dismissCompactDialog();
        editActions.clear();
        root = column(); root.setPadding(dp(8), dp(4), dp(8), dp(4)); root.setBackgroundColor(BACKGROUND);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(dp(8) + insets.getSystemWindowInsetLeft(), dp(4) + insets.getSystemWindowInsetTop(),
                    dp(8) + insets.getSystemWindowInsetRight(), dp(4) + insets.getSystemWindowInsetBottom());
            return insets;
        });
        setContentView(root); root.requestApplyInsets(); return root;
    }
    private void header(LinearLayout parent) {
        int toolbarHeight = dp(Math.max(44, Math.round(30 * getResources().getConfiguration().fontScale)));
        LinearLayout row = row(); row.setGravity(Gravity.CENTER_VERTICAL); row.setBackgroundColor(TOP);
        ImageView logo = new ImageView(this); logo.setImageResource(R.drawable.netvista_logo);
        logo.setContentDescription("NetVista Studio logo"); logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        row.addView(logo, new LinearLayout.LayoutParams(dp(24), dp(24)));
        LinearLayout words = column(); words.setPadding(dp(6), 0, dp(8), 0);
        TextView brand = label("NetVista", 17, TEXT, true); brand.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL)); brand.setPadding(0, 0, 0, 0);
        TextView studio = label("STUDIO", 10, ACCENT, true); studio.setPadding(0, 0, 0, 0); words.addView(brand); words.addView(studio);
        row.addView(words);
        boolean narrowToolbar = getResources().getConfiguration().screenWidthDp < 600;
        if (editorVisible) {
            Button home = button(narrowToolbar ? "⌂" : "Home", this::showHome, true); home.setContentDescription("Studio Home");
            if (narrowToolbar) home.setTextSize(17); row.addView(home);
        }
        projectTitle = label(homeVisible ? "Studio Home" : editorVisible ? project.title : "Account", 12, TEXT, false);
        projectTitle.setSingleLine(true); projectTitle.setEllipsize(TextUtils.TruncateAt.END);
        row.addView(projectTitle, new LinearLayout.LayoutParams(0, toolbarHeight, 1));
        if (editorVisible) {
            if (wideLayout) { row.addView(button("Open", this::pickOpenProject, true)); row.addView(button("Save", this::pickSaveProject, true)); }
            if (!narrowToolbar) { Button export = button("Export", this::exportSettings, true); export.setTextColor(ACCENT); row.addView(export); }
        }
        row.addView(button("⋮", this::overflow, false)); parent.addView(row, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, toolbarHeight));
    }
    private void showLogin() {
        flushFocusedEditor();
        editorVisible = false; homeVisible = false; main.removeCallbacks(playheadTimer); main.removeCallbacks(effectsPreview);
        if (player != null) { player.release(); player = null; }
        status = null; progress = null; accountStatus = null; timeline = null;
        LinearLayout container = screen(); header(container);
        ScrollView scroll = new ScrollView(this); LinearLayout form = column(); form.setPadding(dp(12), dp(24), dp(12), dp(16)); scroll.addView(form);
        form.addView(label("Sign in to NetVista Studio", 17, TEXT, true));
        form.addView(label("Your existing account. Native video editing, projects and exports run on this device.", 13, MUTED, false));
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
        form.addView(label("Native Video, Motion/Effects and Colour workspaces. Desktop photo, 3D, Game Maker and mods are not implemented on Android.", 12, MUTED, false));
        container.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
    }
    private void showHome() {
        if (!liveUi() || transformer != null || account == null || !account.state().canEdit) return;
        flushFocusedEditor();
        main.removeCallbacks(playheadTimer); main.removeCallbacks(effectsPreview);
        if (player != null) { player.release(); player = null; }
        editorVisible = false; homeVisible = true; loginStatus = null; signInButton = null;
        LinearLayout container = screen(); header(container);
        accountStatus = label(account.state().email, 11, MUTED, false); container.addView(accountStatus);
        ScrollView scroll = new ScrollView(this); LinearLayout content = column(); content.setPadding(dp(12), dp(16), dp(12), dp(12)); scroll.addView(content);
        content.addView(label("Studio Home", 20, TEXT, true));
        content.addView(label("Create, continue or open a native video project.", 13, MUTED, false));
        LinearLayout card = panel("VIDEO EDITOR"); card.setBackground(shape(CARD, SEPARATOR)); card.addView(label("Video editing workspace", 17, TEXT, true));
        ImageView artwork = new ImageView(this); artwork.setImageResource(R.drawable.home_video_coast); artwork.setScaleType(ImageView.ScaleType.CENTER_CROP);
        artwork.setContentDescription("NetVista Video Editor coast artwork"); card.addView(artwork, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(160)));
        card.addView(label("Media Pool · Program Monitor · Motion/Effects · Colour · Timeline", 12, MUTED, false));
        LinearLayout actions = row(); actions.addView(weighted(button("Continue edit", this::showEditor, true)));
        actions.addView(weighted(button("New project", this::newProject, true))); actions.addView(weighted(button("Open", this::pickOpenProject, true))); card.addView(actions); content.addView(card);
        content.addView(label("CURRENT LOCAL EDIT", 11, MUTED, true));
        content.addView(label(project.title + " · " + project.clips.size() + " clips · " + project.sources().size() + " sources", 13, TEXT, true));
        content.addView(label("Private draft autosave. Save a portable project to keep a separate backup.", 12, MUTED, false));
        content.addView(label("This Android edition implements Video, Motion/Effects and Colour. Photo, 3D, Game Maker, mods and desktop project compatibility are not included.", 12, MUTED, false));
        container.addView(scroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        status = label(operationBusy ? "Working with local media…" : "Private local draft · save a portable backup", 11, MUTED, false);
        status.setSingleLine(); status.setEllipsize(TextUtils.TruncateAt.END); container.addView(status);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); progress.setIndeterminate(true);
        progress.setVisibility(operationBusy ? View.VISIBLE : View.GONE); container.addView(progress, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(5)));
        cancelExport = null; summary = status; timeline = null; inspector = null; mediaList = null; playButton = null; undoButton = null; redoButton = null; updateEnabled();
    }
    private void showEditor() {
        if (!liveUi() || account == null || !account.state().canEdit) return;
        flushFocusedEditor();
        main.removeCallbacks(playheadTimer); main.removeCallbacks(effectsPreview);
        if (player != null) {
            if (player.isPlaying()) playheadMs = player.getCurrentPosition();
            player.release();
        }
        editorVisible = true; homeVisible = false; loginStatus = null; signInButton = null;
        wideLayout = getResources().getConfiguration().screenWidthDp >= 900 && getResources().getConfiguration().screenHeightDp >= 420;
        LinearLayout container = screen(); header(container);
        mediaPanel = panel("MEDIA POOL"); LinearLayout sourceActions = row();
        sourceActions.addView(weighted(button("Import", this::pickVideos, false)));
        sourceActions.addView(weighted(button("Add", () -> addSources(false), false)));
        sourceActions.addView(weighted(button("Add all", () -> addSources(true), false))); mediaPanel.addView(sourceActions);
        mediaSummary = label("0 sources", 11, MUTED, false); mediaPanel.addView(mediaSummary);
        ScrollView poolScroll = new ScrollView(this); mediaList = column(); poolScroll.addView(mediaList); mediaPanel.addView(poolScroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        inspectorPanel = panel("INSPECTOR"); LinearLayout inspectorTabs = row();
        inspectorTabs.addView(weighted(button("Trim", () -> selectWorkspace(0), false)));
        inspectorTabs.addView(weighted(button("Motion", () -> selectWorkspace(1), false)));
        inspectorTabs.addView(weighted(button("Colour", () -> selectWorkspace(2), false))); inspectorPanel.addView(inspectorTabs);
        ScrollView settingsScroll = new ScrollView(this); inspector = column(); settingsScroll.addView(inspector); inspectorPanel.addView(settingsScroll, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        monitorPanel = panel("PROGRAM MONITOR");
        player = createPreviewPlayer();
        playerView = new PlayerView(this); playerView.setPlayer(player); playerView.setUseController(false);
        playerView.setShutterBackgroundColor(Color.BLACK);
        playerView.setResizeMode(AspectRatioFrameLayout.RESIZE_MODE_FIT); playerView.setBackgroundColor(Color.BLACK); playerView.setKeepContentOnPlayerReset(true);
        monitorPanel.addView(playerView, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        LinearLayout transport = row(); transport.setGravity(Gravity.CENTER_VERTICAL);
        Button previous = button("|◀", () -> seekTimeline(startOf(Math.max(0, clipAt(playheadMs) - 1)), false), true); previous.setContentDescription("Previous clip"); transport.addView(previous);
        playButton = button("▶", this::togglePlay, true); playButton.setTextSize(17); playButton.setContentDescription("Play or pause"); transport.addView(playButton);
        Button stop = button("■", () -> seekTimeline(0, false), true); stop.setContentDescription("Stop and return to start"); transport.addView(stop);
        Button next = button("▶|", () -> seekTimeline(startOf(Math.min(project.clips.size() - 1, clipAt(playheadMs) + 1)), false), true); next.setContentDescription("Next clip"); transport.addView(next);
        timecode = label("00:00:00:00", 11, TEXT, false); timecode.setTypeface(Typeface.MONOSPACE); timecode.setGravity(Gravity.END); transport.addView(timecode, new LinearLayout.LayoutParams(0, dp(44), 1)); monitorPanel.addView(transport);
        LinearLayout workspace = row(); workspace.setBackgroundColor(WORKSPACE);
        if (wideLayout) {
            workspace.addView(mediaPanel, new LinearLayout.LayoutParams(dp(210), ViewGroup.LayoutParams.MATCH_PARENT));
            workspace.addView(monitorPanel, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1));
            workspace.addView(inspectorPanel, new LinearLayout.LayoutParams(dp(240), ViewGroup.LayoutParams.MATCH_PARENT));
        } else {
            LinearLayout adaptive = column(); LinearLayout toggles = row();
            toggles.addView(weighted(button("Media", () -> switchCompactPanel(0), true)));
            toggles.addView(weighted(button("Monitor", () -> switchCompactPanel(1), true)));
            toggles.addView(weighted(button("Inspector", () -> switchCompactPanel(2), true)));
            if (!shortWindow()) adaptive.addView(toggles);
            adaptive.addView(monitorPanel, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
            compactDrawer = column(); adaptive.addView(compactDrawer, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, drawerHeight()));
            workspace.addView(adaptive, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        }
        container.addView(workspace, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        LinearLayout timelinePanel = column(); timelinePanel.setBackgroundColor(WORKSPACE); LinearLayout timelineTools = row(); timelineTools.setGravity(Gravity.CENTER_VERTICAL);
        HorizontalScrollView toolScroll = new HorizontalScrollView(this); toolScroll.setHorizontalScrollBarEnabled(false); LinearLayout timelineActions = row();
        undoButton = button("Undo", this::undoEdit, true); redoButton = button("Redo", this::redoEdit, true); timelineActions.addView(undoButton); timelineActions.addView(redoButton);
        timelineActions.addView(button("Split", this::splitAtPlayhead, true)); timelineActions.addView(button("Duplicate", this::duplicateClip, true)); timelineActions.addView(button("Delete", this::deleteClip, true));
        timelineActions.addView(button("Earlier", () -> move(selected, -1), true)); timelineActions.addView(button("Later", () -> move(selected, 1), true)); toolScroll.addView(timelineActions);
        timelineTools.addView(toolScroll, new LinearLayout.LayoutParams(0, dp(44), 1));
        timelineTools.addView(button("−", () -> timeline.zoomOut(), true)); timelineTools.addView(button("+", () -> timeline.zoomIn(), true)); timelineTools.addView(button("Fit", () -> timeline.fit(), true)); timelinePanel.addView(timelineTools);
        timeline = new StudioTimelineView(this); timeline.setListener(new StudioTimelineView.Listener() {
            @Override public void selected(int index, long position) { selected = index; seekTimeline(position, false); refreshTimeline(false); }
            @Override public void scrubbed(long position) { seekTimeline(position, false); }
            @Override public void reordered(int from, int to) { if (!operationBusy) { flushFocusedEditor(); recordEdit(); project.move(from, to); selected = to; changedEdit(); } }
        });
        timelinePanel.addView(timeline, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1));
        container.addView(timelinePanel, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, timelineHeight()));
        LinearLayout footerNavigation = row(); footerNavigation.addView(weighted(button("Edit", () -> selectWorkspace(0), true)));
        footerNavigation.addView(weighted(button("Effects", () -> selectWorkspace(1), true))); footerNavigation.addView(weighted(button("Colour", () -> selectWorkspace(2), true)));
        footerNavigation.addView(weighted(button("Export", this::exportSettings, true))); if (!shortWindow()) container.addView(footerNavigation);
        LinearLayout bottom = row(); bottom.setGravity(Gravity.CENTER_VERTICAL);
        status = label("Native local editor · select a clip to inspect", 11, MUTED, false); status.setSingleLine(); status.setEllipsize(TextUtils.TruncateAt.END); bottom.addView(status, new LinearLayout.LayoutParams(0, dp(24), 1));
        accountStatus = label(account.state().email, 10, MUTED, false); accountStatus.setSingleLine(); accountStatus.setMaxWidth(dp(180)); accountStatus.setEllipsize(TextUtils.TruncateAt.END); bottom.addView(accountStatus); container.addView(bottom);
        progress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal); progress.setMax(100); progress.setVisibility(View.GONE); container.addView(progress, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(5)));
        cancelExport = button("Cancel export", () -> cancelRendering("Export cancelled. Source media and project are unchanged."), false); cancelExport.setVisibility(View.GONE); container.addView(cancelExport);
        summary = status; refreshTimeline(true); updateEnabled(); if (!wideLayout) switchCompactPanel(compactPanel);
        main.post(playheadTimer);
    }

    private LinearLayout panel(String title) {
        LinearLayout panel = column(); panel.setPadding(dp(8), dp(4), dp(8), dp(4)); panel.setBackground(shape(PANEL, SEPARATOR));
        TextView heading = label(title, 10, MUTED, true); heading.setSingleLine(); heading.setContentDescription(title); panel.addView(heading); return panel;
    }
    private boolean shortWindow() { return getResources().getConfiguration().screenHeightDp < 500; }
    private int timelineHeight() { return dp(shortWindow() ? 140 : wideLayout ? 238 : getResources().getConfiguration().screenHeightDp < 700 ? 180 : 210); }
    private int drawerHeight() { return dp(getResources().getConfiguration().screenHeightDp < 500 ? 90 : 160); }
    private boolean panelDialogLayout() { return getResources().getConfiguration().screenHeightDp < 700; }
    private void switchCompactPanel(int panel) {
        int previousPanel = compactPanel; compactPanel = panel; if (wideLayout || compactDrawer == null) return;
        compactDrawer.removeAllViews();
        // A panel must not consume the monitor on short portrait phone windows.
        if (panelDialogLayout()) {
            compactDrawer.setVisibility(View.GONE);
            if (compactDialog != null && compactDialog.isShowing() && previousPanel == panel) return;
            dismissCompactDialog();
            if (panel != 1) {
                LinearLayout content = panel == 0 ? mediaPanel : inspectorPanel;
                if (content.getParent() instanceof ViewGroup) ((ViewGroup) content.getParent()).removeView(content);
                FrameLayout holder = new FrameLayout(this); holder.addView(content, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(Math.max(150, Math.min(250, getResources().getConfiguration().screenHeightDp - 130)))));
                AlertDialog dialog = new AlertDialog.Builder(this).setTitle(panel == 0 ? "Media Pool" : "Inspector").setView(holder).setPositiveButton("Close", null).create();
                dialog.setOnDismissListener(d -> {
                    View focus = holder.findFocus(); if (focus instanceof EditText) focus.clearFocus();
                    holder.removeAllViews(); if (compactDialog == dialog) { compactDialog = null; compactPanel = 1; }
                });
                compactDialog = dialog; dialog.show();
            }
            return;
        }
        if (panel == 1) compactDrawer.setVisibility(View.GONE);
        else { compactDrawer.setVisibility(View.VISIBLE); compactDrawer.addView(panel == 0 ? mediaPanel : inspectorPanel, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)); }
    }
    private void selectWorkspace(int tab) { flushFocusedEditor(); inspectorTab = tab; refreshInspector(); if (!wideLayout) switchCompactPanel(2); }
    private void dismissCompactDialog() { if (compactDialog != null) { AlertDialog old = compactDialog; compactDialog = null; old.dismiss(); } }
    private void refreshTimeline(boolean updatePreview) {
        if (!liveUi() || !editorVisible || timeline == null) return;
        selected = project.clips.isEmpty() ? -1 : Math.max(0, Math.min(selected, project.clips.size() - 1));
        playheadMs = Math.max(0, Math.min(playheadMs, project.durationMs()));
        projectTitle.setText(project.title); timeline.setProject(project, selected); timeline.setInteractive(!operationBusy && draftReady);
        refreshPool(); refreshInspector(); updatePlayhead(false); updateEnabled();
        if (updatePreview) preview(false);
    }
    private void refreshPool() {
        if (!editorVisible || mediaList == null) return;
        mediaList.removeAllViews(); List<StudioProject.Clip> sources = project.sources(); mediaSummary.setText(sources.size() + " sources · " + project.clips.size() + " timeline clips");
        if (selectedSource == null && !sources.isEmpty()) selectedSource = sources.get(0).uri;
        for (StudioProject.Clip source : sources) {
            LinearLayout item = row(); item.setGravity(Gravity.CENTER_VERTICAL); item.setPadding(dp(6), dp(2), dp(6), dp(2)); item.setMinimumHeight(dp(44));
            item.setBackground(shape(source.uri.equals(selectedSource) ? CONTROL : PANEL, source.uri.equals(selectedSource) ? ACCENT : PANEL));
            TextView icon = label("▣", 16, Color.rgb(53, 111, 159), true); item.addView(icon, new LinearLayout.LayoutParams(dp(25), dp(40)));
            LinearLayout words = column(); TextView name = label(source.name, 12, TEXT, false); name.setSingleLine(); name.setEllipsize(TextUtils.TruncateAt.END); words.addView(name);
            TextView duration = label(time(source.durationMs), 10, MUTED, false); duration.setTypeface(Typeface.MONOSPACE); words.addView(duration); item.addView(words, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
            item.setContentDescription(source.name + ", " + seconds(source.durationMs) + " seconds. Hold to add to timeline."); item.setFocusable(true);
            item.setOnClickListener(v -> { if (!operationBusy) { selectedSource = source.uri; refreshPool(); } });
            item.setOnLongClickListener(v -> { selectedSource = source.uri; addSources(false); return true; }); mediaList.addView(item);
        }
        if (sources.isEmpty()) mediaList.addView(label("Import local videos. Select a source and Add it to the timeline.", 12, MUTED, false));
        setEnabledChildren(mediaPanel, !operationBusy && draftReady);
    }
    private void refreshInspector() {
        if (!editorVisible || inspector == null) return;
        inspector.removeAllViews();
        if (selected < 0 || selected >= project.clips.size()) { inspector.addView(label("Select a timeline clip to edit its trim, motion or colour.", 12, MUTED, false)); return; }
        StudioProject.Clip clip = project.clips.get(selected); inspector.addView(label(clip.name, 12, TEXT, true));
        inspector.addView(label("Clip " + (selected + 1) + " · " + seconds(clip.lengthMs()) + "s", 11, MUTED, false));
        if (inspectorTab == 0) {
            inspector.addView(label("SOURCE TRIM · SECONDS", 10, MUTED, true));
            inField = field("In", InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL); outField = field("Out", InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL);
            inField.setText(seconds(clip.inMs)); outField.setText(seconds(clip.outMs)); inspector.addView(propertyRow("In", inField)); inspector.addView(propertyRow("Out", outField));
            LinearLayout marks = row(); marks.addView(weighted(button("Mark In", () -> mark(true), false))); marks.addView(weighted(button("Mark Out", () -> mark(false), false))); inspector.addView(marks);
            inspector.addView(button("Apply trim", this::applyTrim, false)); inspector.addView(label("Ripple timeline: trimming changes the sequence length. Full source media is retained.", 11, MUTED, false));
        } else if (inspectorTab == 1) {
            inspector.addView(label("MOTION & EFFECTS", 10, MUTED, true));
            effectControl(clip, "Scale %", 0, 5, 800, 100); effectControl(clip, "Rotation °", 1, -360, 360, 1);
            effectControl(clip, "Position X %", 2, -100, 100, 100); effectControl(clip, "Position Y %", 3, -100, 100, 100); effectControl(clip, "Opacity %", 4, 0, 100, 100);
            inspector.addView(label("100% scale fits the full source first. X/Y use half-canvas offsets; +Y moves up. Opacity fades to the black single-track canvas.", 11, MUTED, false));
            inspector.addView(button("Reset motion", () -> resetSettings(false), false));
        } else {
            inspector.addView(label("PRIMARY COLOUR", 10, MUTED, true));
            effectControl(clip, "Brightness %", 5, -100, 100, 100); effectControl(clip, "Contrast %", 6, 0, 400, 100); effectControl(clip, "Saturation %", 7, 0, 200, 100);
            inspector.addView(label("Adjustments belong to the selected clip and match the monitor and exported movie. Contrast 100% is neutral.", 11, MUTED, false));
            inspector.addView(button("Reset colour", () -> resetSettings(true), false));
        }
        setEnabledChildren(inspector, !operationBusy && draftReady);
    }
    private LinearLayout propertyRow(String name, View control) {
        LinearLayout row = row(); row.setGravity(Gravity.CENTER_VERTICAL); TextView title = label(name, 12, MUTED, false); title.setSingleLine();
        row.addView(title, new LinearLayout.LayoutParams(dp(64), dp(44))); row.addView(control, new LinearLayout.LayoutParams(0, dp(44), 1)); return row;
    }
    private void effectControl(StudioProject.Clip clip, String name, int parameter, float min, float max, float multiplier) {
        LinearLayout row = row(); row.setGravity(Gravity.CENTER_VERTICAL);
        float fontScale = Math.max(1f, getResources().getConfiguration().fontScale);
        TextView title = label(name, 11, MUTED, false); title.setSingleLine();
        if (fontScale > 1.3f) inspector.addView(title);
        else row.addView(title, new LinearLayout.LayoutParams(dp(78), dp(44)));
        EditText value = field(name, InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL | InputType.TYPE_NUMBER_FLAG_SIGNED);
        value.setText(number(displayedSetting(clip.settings, parameter, multiplier))); value.setSelectAllOnFocus(true); value.setImeOptions(EditorInfo.IME_ACTION_DONE); value.setContentDescription(name);
        SeekBar slider = new SeekBar(this); slider.setMax(1000); slider.setMinimumHeight(dp(44)); slider.setContentDescription(name + " slider");
        slider.setProgress(Math.round((displayedSetting(clip.settings, parameter, multiplier) - min) / (max - min) * 1000));
        row.addView(slider, new LinearLayout.LayoutParams(0, dp(44), 1)); row.addView(value, new LinearLayout.LayoutParams(dp(Math.round(58 * fontScale)), dp(44))); inspector.addView(row);
        slider.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onStartTrackingTouch(SeekBar bar) { if (!operationBusy) { if (player != null) player.pause(); recordEdit(); } }
            @Override public void onProgressChanged(SeekBar bar, int progress, boolean fromUser) {
                if (!fromUser || operationBusy || !project.clips.contains(clip)) return;
                float amount = min + (max - min) * progress / 1000f; value.setText(number(amount)); setSetting(clip, parameter, nativeSetting(parameter, amount, multiplier)); scheduleEffectsPreview();
            }
            @Override public void onStopTrackingTouch(SeekBar bar) { autosave(); preview(false); updateEnabled(); }
        });
        Runnable commit = () -> {
            if (operationBusy || !project.clips.contains(clip)) return;
            try {
                float amount = Float.parseFloat(value.getText().toString()); if (!Float.isFinite(amount) || amount < min || amount > max) throw new IllegalArgumentException();
                // Controls display one decimal. A blur without an edit must not
                // round a slider value or create an extra Undo snapshot.
                // A legacy saved contrast can exceed the visible factor range.
                // Blurring its clamped display must preserve the exact saved value.
                if (!value.getText().toString().equals(number(displayedSetting(clip.settings, parameter, multiplier)))) {
                    if (player != null) player.pause(); recordEdit(); setSetting(clip, parameter, nativeSetting(parameter, amount, multiplier));
                    slider.setProgress(Math.round((amount - min) / (max - min) * 1000)); autosave(); preview(false); updateEnabled();
                }
            } catch (Exception e) { message(name + " must be between " + number(min) + " and " + number(max) + "."); value.setText(number(displayedSetting(clip.settings, parameter, multiplier))); }
        };
        value.setOnFocusChangeListener((field, focused) -> { if (!focused) commit.run(); });
        value.setOnEditorActionListener((field, action, event) -> {
            if (action != EditorInfo.IME_ACTION_DONE) return false;
            commit.run(); value.clearFocus(); return true;
        });
    }
    private static float setting(StudioProject.ClipSettings settings, int parameter) {
        switch (parameter) { case 0: return settings.scale; case 1: return settings.rotationDegrees; case 2: return settings.positionX; case 3: return settings.positionY; case 4: return settings.opacity; case 5: return settings.brightness; case 6: return settings.contrast; default: return settings.saturation; }
    }
    private static float displayedSetting(StudioProject.ClipSettings settings, int parameter, float multiplier) {
        return parameter == 6 ? GradeControlValues.contrastPercent(settings.contrast) : setting(settings, parameter) * multiplier;
    }
    private static float nativeSetting(int parameter, float displayedValue, float multiplier) {
        return parameter == 6 ? GradeControlValues.nativeContrast(displayedValue) : displayedValue / multiplier;
    }
    private void setSetting(StudioProject.Clip clip, int parameter, float value) {
        StudioProject.ClipSettings s = clip.settings;
        clip.settings = new StudioProject.ClipSettings(parameter == 0 ? value : s.scale, parameter == 1 ? value : s.rotationDegrees,
                parameter == 2 ? value : s.positionX, parameter == 3 ? value : s.positionY, parameter == 4 ? value : s.opacity,
                parameter == 5 ? value : s.brightness, parameter == 6 ? value : s.contrast, parameter == 7 ? value : s.saturation);
    }
    private void resetSettings(boolean colour) {
        if (operationBusy || selected < 0) return; flushFocusedEditor(); recordEdit(); StudioProject.Clip clip = project.clips.get(selected); StudioProject.ClipSettings s = clip.settings;
        clip.settings = colour ? new StudioProject.ClipSettings(s.scale, s.rotationDegrees, s.positionX, s.positionY, s.opacity, 0, 0, 1)
                : new StudioProject.ClipSettings(1, 0, 0, 0, 1, s.brightness, s.contrast, s.saturation); changedEdit();
    }
    private void scheduleEffectsPreview() { preview(false); }

    private CompositionPlayer createPreviewPlayer() {
        CompositionPlayer created = new CompositionPlayer.Builder(this).build();
        created.addListener(new Player.Listener() {
            @Override public void onIsPlayingChanged(boolean playing) {
                if (liveUi() && player == created && playButton != null) playButton.setText(playing ? "Ⅱ" : "▶");
            }
            @Override public void onPlayerError(PlaybackException error) {
                if (!liveUi() || player != created) return;
                Log.w("NetVistaPreview", "Native preview failed: " + error.getErrorCodeName(), error);
                message(error.errorCode == PlaybackException.ERROR_CODE_TIMEOUT
                        ? "Preview update timed out. Press Play to retry the current edit; your sources and project are unchanged."
                        : "Preview unavailable: " + error.getErrorCodeName() + ". Press Play to retry; your project is unchanged.");
            }
            @Override public void onPlaybackStateChanged(int state) {
                if (state == Player.STATE_READY) previewReady(created);
            }
            @Override public void onRenderedFirstFrame() { previewReady(created); }
        });
        return created;
    }

    private void previewReady(CompositionPlayer current) {
        if (liveUi() && player == current && !previewPending
                && current.getPlaybackState() == Player.STATE_READY && current.getPlayerError() == null) {
            message("Program monitor ready — current edit.");
        }
    }

    private void recreateErroredPreviewPlayer() {
        if (player == null || player.getPlayerError() == null) return;
        // Media3 1.11.1 keeps CompositionPlayer's playbackException sticky even
        // across prepare/stop/setComposition. Retry the latest model with a new
        // native engine, only on an explicit preview request after a real error.
        CompositionPlayer failed = player;
        playerView.setKeepContentOnPlayerReset(false);
        playerView.setPlayer(null);
        player = null; // Ignore late callbacks from the released engine.
        try { failed.release(); }
        catch (RuntimeException error) { Log.w("NetVistaPreview", "Errored native preview release failed", error); }
        player = createPreviewPlayer();
    }

    private void preview(boolean play) {
        if (!liveUi() || !editorVisible || operationBusy || player == null) return;
        // One latest project snapshot per burst of edits. Rebuilding compositions
        // for each rapid Delete/Add/Undo/Redo can flood native codec reconfiguration
        // and time out, especially on slower tablets. Paused edit intent stays
        // authoritative until the coalesced composition has actually prepared.
        player.pause(); previewPending = true; previewPlayWhenReady = play;
        if (project.clips.isEmpty()) {
            // Retaining a frame is useful during edits, but an empty timeline
            // must never display the deleted clip as if it still exists.
            playerView.setKeepContentOnPlayerReset(false);
            playerView.setPlayer(null);
        }
        main.removeCallbacks(effectsPreview);
        main.postDelayed(effectsPreview, 120);
    }
    private void applyPreview(boolean play) {
        if (!liveUi() || !editorVisible || !foreground || operationBusy || player == null) { previewPending = false; return; }
        if (project.clips.isEmpty()) {
            // Deletion already removes the video surface immediately. Do not
            // wait for that obsolete graph to render its first frame/READY:
            // it no longer has a surface, and no decoder is needed at all.
            previewPending = false;
            try {
                playerView.setKeepContentOnPlayerReset(false); player.stop(); playerView.setPlayer(null); updatePlayhead(false);
            } catch (RuntimeException error) {
                Log.w("NetVistaPreview", "Could not stop deleted native preview", error);
            }
            return;
        }
        if (player.getPlayerError() == null && player.getPlaybackState() == Player.STATE_BUFFERING) {
            // Do not tear down a native graph while its codecs/surfaces are
            // still preparing. Keep one explicit latest edit pending; once the
            // prior graph is ready (or has a real error), apply only that edit.
            previewPending = true;
            main.removeCallbacks(effectsPreview);
            main.postDelayed(effectsPreview, 50);
            return;
        }
        previewPending = false;
        try {
            recreateErroredPreviewPlayer();
            playerView.setKeepContentOnPlayerReset(true);
            playerView.setPlayer(player); player.setComposition(MobileExport.composition(project.copy(), files), Math.min(playheadMs, Math.max(0, project.durationMs() - 1)));
            player.prepare(); player.setPlayWhenReady(play); updatePlayhead(false);
        } catch (Exception e) { Log.w("NetVistaPreview", "Native composition update failed", e); message("Preview unavailable: " + e.getMessage()); }
    }
    private void togglePlay() {
        if (operationBusy || project.clips.isEmpty() || player == null) { message("Add a source to the timeline first."); return; }
        flushFocusedEditor();
        if (player.isPlaying()) {
            playheadMs = Math.max(0, Math.min(project.durationMs(), player.getCurrentPosition()));
            player.pause(); updatePlayhead(false);
        } else {
            if (playheadMs >= project.durationMs()) { playheadMs = 0; player.seekTo(0); }
            if (previewPending || player.getPlayerError() != null || player.getPlaybackState() == Player.STATE_IDLE) preview(true); else player.play();
        }
    }
    private void seekTimeline(long position, boolean play) {
        if (operationBusy || project.clips.isEmpty()) return;
        flushFocusedEditor();
        playheadMs = Math.max(0, Math.min(position, project.durationMs())); int index = clipAt(playheadMs);
        if (selected != index) { selected = index; refreshInspector(); timeline.setProject(project, selected); }
        if (player != null) {
            if (previewPending || player.getPlayerError() != null || player.getPlaybackState() == Player.STATE_IDLE) preview(play);
            else { player.pause(); player.seekTo(Math.min(playheadMs, Math.max(0, project.durationMs() - 1))); if (play) player.play(); }
        }
        updatePlayhead(false);
    }
    private void updatePlayhead(boolean follow) {
        if (timecode != null) timecode.setText(frameTime(playheadMs));
        if (timeline != null) timeline.setPlayhead(playheadMs, follow);
    }
    private long startOf(int index) { long value = 0; for (int i = 0; i < Math.max(0, index) && i < project.clips.size(); i++) value += project.clips.get(i).lengthMs(); return value; }
    private int clipAt(long position) { long end = 0; for (int i = 0; i < project.clips.size(); i++) { end += project.clips.get(i).lengthMs(); if (position < end) return i; } return project.clips.size() - 1; }
    private void move(int index, int direction) {
        int target = index + direction; if (operationBusy || index < 0 || target < 0 || target >= project.clips.size()) return;
        flushFocusedEditor();
        recordEdit(); project.move(index, target); selected = target; playheadMs = startOf(selected); changedEdit();
    }
    private void mark(boolean in) {
        if (operationBusy || selected < 0 || clipAt(playheadMs) != selected) return;
        StudioProject.Clip clip = project.clips.get(selected); long position = Math.min(clip.outMs, clip.inMs + playheadMs - startOf(selected));
        (in ? inField : outField).setText(seconds(position));
    }
    private void applyTrim() {
        if (operationBusy || selected < 0) return;
        try {
            double in = Double.parseDouble(inField.getText().toString()), out = Double.parseDouble(outField.getText().toString());
            if (!Double.isFinite(in) || !Double.isFinite(out) || in < 0 || out > project.clips.get(selected).durationMs / 1000.0 || out <= in) throw new IllegalArgumentException();
            recordEdit(); project.clips.get(selected).trim(Math.round(in * 1000), Math.round(out * 1000)); playheadMs = startOf(selected); changedEdit(); message("Trim applied to monitor and export.");
        } catch (Exception e) { message("Out must be after In, inside the source video."); }
    }
    private void addSources(boolean all) {
        if (operationBusy || !draftReady) return; flushFocusedEditor(); List<StudioProject.Clip> sources = project.sources();
        if (sources.isEmpty()) { message("Import sources first."); return; }
        recordEdit(); int first = project.clips.size();
        for (StudioProject.Clip source : sources) if (all || source.uri.equals(selectedSource)) {
            if (project.clips.size() >= StudioProject.MAX_CLIPS) { message("Timeline limit: 500 clips."); break; }
            project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), source.uri, source.name, source.durationMs, 0, source.durationMs));
        }
        if (project.clips.size() > first) { selected = first; playheadMs = startOf(first); changedEdit(); }
    }
    private void splitAtPlayhead() {
        if (operationBusy || selected < 0) return;
        flushFocusedEditor();
        StudioProject.Clip clip = project.clips.get(selected); long sourcePosition = clip.inMs + playheadMs - startOf(selected);
        if (sourcePosition <= clip.inMs || sourcePosition >= clip.outMs) { message("Place the playhead inside a clip before splitting."); return; }
        try { recordEdit(); project.split(selected, sourcePosition); selected++; changedEdit(); message("Split at playhead. Source media is shared, not copied."); }
        catch (IllegalArgumentException e) { message(e.getMessage()); }
    }
    private void duplicateClip() { if (operationBusy || selected < 0) return; flushFocusedEditor(); try { recordEdit(); project.duplicate(selected); selected++; playheadMs = startOf(selected); changedEdit(); } catch (IllegalArgumentException e) { message(e.getMessage()); } }
    private void deleteClip() { if (operationBusy || selected < 0) return; flushFocusedEditor(); recordEdit(); project.clips.remove(selected); playheadMs = Math.min(playheadMs, project.durationMs()); changedEdit(); }
    private void recordEdit() { undo.addLast(new EditState(project, selected, playheadMs)); while (undo.size() > 80) undo.removeFirst(); redo.clear(); }
    private void undoEdit() { if (operationBusy) return; flushFocusedEditor(); if (undo.isEmpty()) return; redo.addLast(new EditState(project, selected, playheadMs)); restoreEdit(undo.removeLast()); }
    private void redoEdit() { if (operationBusy) return; flushFocusedEditor(); if (redo.isEmpty()) return; undo.addLast(new EditState(project, selected, playheadMs)); restoreEdit(redo.removeLast()); }
    private void restoreEdit(EditState edit) { project = edit.project.copy(); selected = edit.selected; playheadMs = edit.playhead; changedEdit(); }
    private void changedEdit() { autosave(); if (editorVisible) refreshTimeline(true); else if (homeVisible) showHome(); }

    private void newProject() {
        if (operationBusy || !draftReady) return;
        new AlertDialog.Builder(this).setTitle("New video project")
                .setMessage("Save a portable backup first if needed. Current imported media remains in private storage and can be restored with Undo.")
                .setNegativeButton("Cancel", null).setPositiveButton("New project", (d, w) -> {
                    if (!liveUi() || operationBusy || !account.state().canEdit) return;
                    recordEdit(); project = new StudioProject(); selected = -1; selectedSource = null; playheadMs = 0;
                    if (player != null) { player.release(); player = null; }
                    autosave(); showEditor();
                }).show();
    }
    private void overflow() {
        String[] options = editorVisible ? new String[]{"Studio Home", "Import sources", "Media Pool", "Inspector", "Motion/Effects", "Colour", "Open project", "Save project", "Project settings", "Account", "Export MP4", "About & licenses"}
                : new String[]{"Video Editor", "Open project", "Account", "About & licenses"};
        new AlertDialog.Builder(this).setTitle("NetVista Studio").setItems(options, (dialog, index) -> {
            if (editorVisible) {
                switch (index) {
                    case 0: showHome(); break; case 1: pickVideos(); break; case 2: switchCompactPanel(0); break;
                    case 3: switchCompactPanel(2); break; case 4: selectWorkspace(1); break; case 5: selectWorkspace(2); break;
                    case 6: pickOpenProject(); break; case 7: pickSaveProject(); break; case 8: projectMenu(); break;
                    case 9: accountPanel(); break; case 10: exportSettings(); break; default: about(); break;
                }
            } else {
                if (index == 0 && account.state().canEdit) showEditor();
                else if (index == 1 && account.state().canEdit) pickOpenProject();
                else if (index == 2) accountPanel(); else about();
            }
        }).show();
    }
    private void accountPanel() {
        StudioAccount.Snapshot state = account.state();
        new AlertDialog.Builder(this).setTitle("NetVista account")
                .setMessage((state.email.isEmpty() ? "Sign in with your existing account." : state.email) + "\n\n" + state.status)
                .setPositiveButton("Check now", (d, w) -> account.checkAsync(true))
                .setNeutralButton("Manage account", (d, w) -> startActivity(new Intent(Intent.ACTION_VIEW, Uri.parse(StudioAccount.ACCOUNT_URL))))
                .setNegativeButton(state.canEdit ? "Sign out" : "Close", (d, w) -> { if (state.canEdit) { autosave(); account.signOut(); } }).show();
    }
    private void exportSettings() {
        if (operationBusy || !draftReady) return; flushFocusedEditor(); if (!editorVisible) showEditor();
        LinearLayout options = column(); options.setPadding(dp(12), dp(8), dp(12), dp(8));
        options.addView(label("MP4 · H.264 video · AAC audio · 30 fps", 12, TEXT, true));
        options.addView(label("Fits each source to the selected canvas. Motion and colour match the monitor composition; sources stay local.", 12, MUTED, false));
        Button canvas = button(project.width + " × " + project.height + " · change canvas", () -> canvasMenu(), false); options.addView(canvas);
        new AlertDialog.Builder(this).setTitle("Export workspace").setView(options).setNegativeButton("Cancel", null)
                .setPositiveButton("Render MP4", (d, w) -> export()).show();
    }
    private void canvasMenu() {
        if (operationBusy) return;
        new AlertDialog.Builder(this).setTitle("Output canvas · 30 fps")
                .setItems(new String[]{"1920 × 1080 · landscape", "1280 × 720 · landscape", "1080 × 1920 · portrait"}, (dialog, size) -> {
                    if (!liveUi() || operationBusy || !account.state().canEdit) return;
                    recordEdit(); project.width = size == 1 ? 1280 : size == 2 ? 1080 : 1920;
                    project.height = size == 1 ? 720 : size == 2 ? 1920 : 1080; changedEdit();
                }).show();
    }

    private void pickVideos() {
        if (operationBusy || !draftReady || project.sources().size() >= StudioProject.MAX_ASSETS) return;
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.setType("video/*");
        intent.addCategory(Intent.CATEGORY_OPENABLE); intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION); startActivityForResult(intent, IMPORT_VIDEO);
    }
    private void pickOpenProject() {
        if (operationBusy || !draftReady) return; flushFocusedEditor();
        new AlertDialog.Builder(this).setTitle("Open a mobile project?")
                .setMessage("Your current edit is autosaved privately. Save a self-contained project first if you want to keep both edits.")
                .setNegativeButton("Cancel", null).setPositiveButton("Open", (d, w) -> {
                    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.setType("*/*"); intent.addCategory(Intent.CATEGORY_OPENABLE);
                    startActivityForResult(intent, OPEN_PROJECT);
                }).show();
    }
    private void pickSaveProject() {
        if (operationBusy || !draftReady) return; flushFocusedEditor();
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
        flushFocusedEditor();
        recordEdit();
        setBusy(true, "Copying selected videos into private storage…");
        long ticket = ++operationGeneration;
        StudioProject target = project.copy();
        int available = StudioProject.MAX_ASSETS - project.sources().size();
        io.execute(() -> {
            List<StudioProject.Clip> imported = new ArrayList<>(); List<String> failures = new ArrayList<>();
            for (Uri uri : uris.subList(0, Math.min(available, uris.size()))) {
                String id = UUID.randomUUID().toString(); File copy = null;
                try {
                    String name = displayName(uri); copy = files.importVideo(uri, id); long duration = videoDuration(copy);
                    imported.add(new StudioProject.Clip(id, "media/" + id + ".video", name, duration, 0, duration));
                } catch (Exception e) { if (copy != null) copy.delete(); failures.add("One video was unreadable, unsupported or exceeded 4 GiB."); }
            }
            target.assets.addAll(imported);
            String saveWarning = "";
            try {
                if (!saveDraftIfCurrent(target)) { removePrivateCopies(imported); return; }
            } catch (Exception e) {
                if (destroyed || ACTIVE_ACTIVITY.get() != activityGeneration) { removePrivateCopies(imported); return; }
                saveWarning = " Private autosave failed—use Save to keep a project backup.";
            }
            String result = imported.size() + " sources imported. Select Add or Add all." + (failures.isEmpty() ? "" : " " + failures.size() + " could not be imported.") + saveWarning;
            postResult(ticket, () -> {
                project = target; if (!imported.isEmpty()) selectedSource = imported.get(0).uri;
                setBusy(false, result); if (editorVisible) { refreshTimeline(false); if (!wideLayout) switchCompactPanel(0); } else if (homeVisible) showHome();
            });
        });
    }
    private void loadProject(Uri source) {
        flushFocusedEditor();
        recordEdit();
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
                // Validate each real source once; shared instances retain separate effects.
                java.util.Map<String, Long> durations = new java.util.HashMap<>();
                for (StudioProject.Clip clip : loaded.sources()) durations.put(clip.uri, videoDuration(files.mediaFile(clip)));
                for (int i = 0; i < loaded.assets.size(); i++) {
                    StudioProject.Clip clip = loaded.assets.get(i); long actual = durations.get(clip.uri);
                    loaded.assets.set(i, new StudioProject.Clip(clip.id, clip.uri, clip.name, actual, 0, actual));
                }
                for (int i = 0; i < loaded.clips.size(); i++) {
                    StudioProject.Clip clip = loaded.clips.get(i); long actual = durations.get(clip.uri);
                    loaded.clips.set(i, new StudioProject.Clip(clip.id, clip.uri, clip.name, actual, clip.inMs, clip.outMs, clip.settings.copy()));
                }
                if (!saveDraftIfCurrent(loaded)) { removePrivateCopies(loaded.sources()); return; }
                postResult(ticket, () -> {
                    if (player != null) { player.release(); player = null; }
                    project = loaded; selected = loaded.clips.isEmpty() ? -1 : 0; playheadMs = 0; selectedSource = null;
                    setBusy(false, "Project loaded with its media, motion and colour."); showEditor();
                });
            } catch (Exception e) {
                // These are new private copies created by this failed import, not
                // originals, current-project media, or files from the provider.
                if (imported != null) removePrivateCopies(imported.sources());
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
        flushFocusedEditor();
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
            if (player != null) player.stop(); setBusy(true, "Rendering MP4 · keep the app open"); cancelExport.setVisibility(View.VISIBLE);
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
                                .setPositiveButton("Rename", (d, w) -> { if (!liveUi() || operationBusy || !account.state().canEdit) return; recordEdit(); String text = title.getText().toString().trim(); project.title = text.isEmpty() ? "Untitled edit" : text.substring(0, Math.min(text.length(), 200)); changedEdit(); }).show();
                    } else if (which == 1) {
                        canvasMenu();
                    } else if (which == 2) {
                        newProject();
                    } else if (which == 3) account.checkAsync(true);
                    else new AlertDialog.Builder(this).setTitle("Sign out?").setMessage("Your edit is autosaved privately. You can reopen it after signing in.")
                                .setNegativeButton("Cancel", null).setPositiveButton("Sign out", (d, w) -> { autosave(); account.signOut(); }).show();
                }).show();
    }
    private void about() {
        String text = "NetVista Studio 1.4.0 · Beta 7 · Android mobile edition\n\nNative Video, Motion/Effects and Colour workspaces: source pool, program monitor, graphical timeline, trims/split/duplicate/order, undo/redo, portable projects and H.264/AAC MP4 export. Motion and primary colour use the same composition in monitor and export.\n\nThis is not full desktop feature parity. No independent multitrack placement/mixing, transitions, keyframes, LUTs/advanced grading, photo/3D/Game Maker, mods or desktop project compatibility. The A1 lane represents linked source audio, not a separate editable track. Opacity fades to the black canvas. Projects embed original videos; keep backups before uninstalling. Android may defer background account checks. Exports require the app to remain foreground.\n\nOpen-source notices:\n";
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
        if (busy) flushFocusedEditor();
        operationBusy = busy; updateEnabled(); message(message);
        if (progress != null) { progress.setVisibility(busy ? View.VISIBLE : View.GONE); progress.setIndeterminate(true); }
        if (editorVisible) refreshTimeline(false);
        if (!busy && foreground && editorVisible && player != null && player.getPlaybackState() == Player.STATE_IDLE) preview(false);
        if (!busy && pendingLayoutRebuild) { pendingLayoutRebuild = false; if (editorVisible) showEditor(); else if (homeVisible) showHome(); }
    }
    private void updateEnabled() {
        for (Button action : editActions) action.setEnabled(!operationBusy && draftReady);
        if (undoButton != null) undoButton.setEnabled(!operationBusy && !undo.isEmpty());
        if (redoButton != null) redoButton.setEnabled(!operationBusy && !redo.isEmpty());
        if (timeline != null) timeline.setInteractive(!operationBusy && draftReady);
    }
    private void setEnabledChildren(View view, boolean enabled) {
        view.setEnabled(enabled);
        if (view instanceof ViewGroup) for (int i = 0; i < ((ViewGroup) view).getChildCount(); i++) setEnabledChildren(((ViewGroup) view).getChildAt(i), enabled);
    }
    private void flushFocusedEditor() {
        if (compactDialog != null && compactDialog.getWindow() != null) { View focus = compactDialog.getWindow().getDecorView().findFocus(); if (focus instanceof EditText) focus.clearFocus(); }
        if (root != null) { View focus = root.findFocus(); if (focus instanceof EditText) focus.clearFocus(); }
    }
    private void message(String value) { if (!liveUi()) return; if (status != null && (editorVisible || homeVisible)) status.setText(value == null ? "Operation unavailable." : value); }
    @Override public void onConfigurationChanged(Configuration configuration) { super.onConfigurationChanged(configuration); if (operationBusy) pendingLayoutRebuild = true; else if (editorVisible) showEditor(); else if (homeVisible) showHome(); }
    @Override protected void onResume() { super.onResume(); foreground = true; if (account != null) { account.checkAsync(true); main.removeCallbacks(accountTimer); main.post(accountTimer); } main.removeCallbacks(playheadTimer); if (editorVisible) { main.post(playheadTimer); if (!operationBusy && player != null) preview(false); } }
    @Override protected void onStop() { foreground = false; main.removeCallbacks(accountTimer); main.removeCallbacks(playheadTimer); main.removeCallbacks(effectsPreview); flushFocusedEditor(); if (player != null) player.pause(); if (renderingFile != null) cancelRendering("Export cancelled when the app left the foreground. Keep the app open while rendering."); if (editorVisible || homeVisible) autosave(); super.onStop(); }
    @Override protected void onSaveInstanceState(Bundle saved) { if (completedMovie != null) saved.putString("rendered_movie", completedMovie.getName()); super.onSaveInstanceState(saved); }
    @Override protected void onDestroy() {
        destroyed = true; operationGeneration++; editorVisible = false;
        dismissCompactDialog();
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
    private TextView label(String value, int size, int color, boolean bold) { TextView text = new TextView(this); text.setText(value); text.setTextSize(size); text.setTextColor(color); text.setPadding(0, dp(3), 0, dp(3)); if (bold) text.setTypeface(Typeface.DEFAULT, Typeface.BOLD); return text; }
    private Button button(String value, Runnable action, boolean editing) {
        Button button = new Button(this); button.setText(value); button.setAllCaps(false); button.setSingleLine(true); button.setEllipsize(TextUtils.TruncateAt.END);
        button.setTextSize(12); button.setTextColor(TEXT); button.setMinWidth(dp(44)); button.setMinimumWidth(dp(44)); button.setMinHeight(dp(44)); button.setMinimumHeight(dp(44));
        button.setPadding(dp(7), 0, dp(7), 0); button.setBackgroundTintList(ColorStateList.valueOf(CONTROL)); button.setContentDescription(value);
        button.setOnClickListener(v -> { flushFocusedEditor(); action.run(); }); if (editing) editActions.add(button); return button;
    }
    private EditText field(String hint, int type) { EditText field = new EditText(this); field.setHint(hint); field.setTextColor(TEXT); field.setHintTextColor(MUTED); field.setInputType(type); field.setSingleLine(true); field.setTextSize(12); field.setMinimumHeight(dp(44)); field.setPadding(dp(6), 0, dp(6), 0); field.setBackground(shape(CONTROL, SEPARATOR)); return field; }
    private GradientDrawable shape(int color, int border) { GradientDrawable value = new GradientDrawable(); value.setColor(color); value.setCornerRadius(dp(6)); value.setStroke(dp(1), border); return value; }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private static String filename(String name) { String value = name.replaceAll("[^A-Za-z0-9._ -]", "_").trim(); return value.isEmpty() ? "NetVista edit" : value.substring(0, Math.min(value.length(), 80)); }
    private static String seconds(long milliseconds) { return String.format(Locale.ROOT, "%.3f", milliseconds / 1000.0); }
    private static String number(float value) { return String.format(Locale.ROOT, "%.1f", value); }
    private static String frameTime(long value) { long seconds = value / 1000; return String.format(Locale.ROOT, "%02d:%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60, (value % 1000) * 30 / 1000); }
    private static String time(long milliseconds) { return String.format(Locale.ROOT, "%02d:%02d.%03d", milliseconds / 60000, (milliseconds / 1000) % 60, milliseconds % 1000); }
}
