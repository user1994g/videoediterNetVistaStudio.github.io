package com.netvistastudio.editor.android;

import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Rect;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.AtomicFile;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.EditorInfo;
import android.webkit.WebView;
import android.widget.Button;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.ScrollView;
import android.widget.TextView;
import androidx.annotation.OptIn;
import androidx.media3.common.Player;
import androidx.media3.common.util.ExperimentalApi;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.transformer.CompositionPlayer;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;
import static org.junit.Assume.assumeTrue;

/**
 * Real native Activity, Views, local codecs and device screenshots. The test-only verified
 * Snapshot is held only in memory: no tokens, sign-in requests, account writes or auth bypass
 * are added to production. Existing draft bytes are restored after all Activity IO finishes.
 */
@UnstableApi
@OptIn(markerClass = ExperimentalApi.class)
@RunWith(AndroidJUnit4.class)
public final class NativeWorkspaceUiTest {
    @Test(timeout = 180000)
    public void homePanelsTimelineEditsAndSavedInspectorWorkOnActualWindow() throws Exception {
        assertFalse(Looper.myLooper() == Looper.getMainLooper());
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        Context context = instrumentation.getTargetContext();
        // Never let a developer/device account accidentally make real service calls in QA.
        assumeTrue("Run native UI QA on a clean install without saved account credentials",
                !context.getSharedPreferences("encrypted_account", Context.MODE_PRIVATE).contains("ciphertext"));
        ProjectFiles files = new ProjectFiles(context);
        AtomicFile draft = new AtomicFile(new File(context.getFilesDir(), "mobile-draft.json"));
        byte[] originalDraft = readExistingDraft(draft);
        File scratch = new File(context.getCacheDir(), "native-ui-" + UUID.randomUUID());
        assertTrue(scratch.mkdir());
        List<File> ownedMedia = new ArrayList<>();
        Harness ui = null;
        try {
            StudioProject project = fixtureProject(instrumentation, files, scratch, ownedMedia);
            files.saveDraft(project);
            MainActivity activity = (MainActivity) instrumentation.startActivitySync(
                    new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            ui = new Harness(instrumentation, context, activity);
            Harness current = ui;
            waitUntil("Private draft restoration completes before test account injection", 15000,
                    () -> current.main(() -> (Boolean) field(activity, "draftReady")));
            StudioAccount account = current.main(() -> (StudioAccount) field(activity, "account"));
            // Drain account-store restoration and its queued listener publication first.
            ((ExecutorService) field(account, "worker")).submit(() -> {}).get(15, TimeUnit.SECONDS);
            instrumentation.waitForIdleSync();
            ui.installInMemoryTestSnapshot(account);

            assertTrue(ui.main(() -> (Boolean) field(activity, "homeVisible")));
            ImageView artwork = ui.main(() -> (ImageView) findDescription(current.root(), "NetVista Video Editor coast artwork"));
            assertNotNull("Studio Home uses the original native coast artwork", artwork);
            ui.reveal(artwork);
            ui.main(() -> { assertNotNull(artwork.getDrawable()); assertTrue(artwork.getWidth() > 100); return null; });
            ui.assertCompactNativeControls(ui.root());
            ui.capture("studio-home");
            ui.click("Continue edit");
            ui.waitPreview();
            ui.assertEditorLayout();
            ui.click("Fit");
            ui.assertGraphicalTimeline();
            ui.capture("editor-initial");

            // A pre-existing maximum native contrast is outside the visible 400% factor cap.
            // Inspecting it and editing a different grade must never silently normalize it.
            ui.tapTimeline(3000, false);
            ui.openWorkspace("Colour", "Colour");
            ui.assertGradeDisplay("Contrast %", 400f);
            ui.edit("Brightness %", "10.0", true);
            ui.clickWithin(ui.panel("inspectorPanel"), "Motion");
            ui.closeCompactDialog();
            assertEquals("Clamped legacy contrast remains exactly native 1 after edit/blur/workspace change", 1f,
                    ui.project().clips.get(1).settings.contrast, 0f);
            assertEquals(0.1f, ui.project().clips.get(1).settings.brightness, 0.000001f);
            ui.drainActivityIo();
            assertEquals("Actual autosave preserves legacy native contrast, not its clamped display", 1f,
                    files.loadDraft().clips.get(1).settings.contrast, 0f);

            // Scrub the real Canvas timeline, then exercise the native edit toolbar.
            long originalDuration = ui.project().durationMs();
            ui.tapTimeline(900, true);
            ui.click("Split");
            StudioProject split = ui.project();
            assertEquals(3, split.clips.size()); assertEquals(originalDuration, split.durationMs());
            assertEquals(split.clips.get(0).uri, split.clips.get(1).uri);
            assertNotEquals(split.clips.get(0).id, split.clips.get(1).id);
            assertTrue("Native scrub determines a real interior source split", split.clips.get(0).outMs > 500 && split.clips.get(0).outMs < 1300);
            ui.click("Duplicate"); assertEquals(4, ui.project().clips.size());
            ui.click("Undo"); assertEquals(3, ui.project().clips.size());
            ui.click("Redo"); assertEquals(4, ui.project().clips.size());
            ui.click("Delete"); assertEquals(3, ui.project().clips.size());
            ui.click("Undo"); assertEquals(4, ui.project().clips.size());
            ui.click("Redo"); assertEquals(3, ui.project().clips.size());

            while (!ui.project().clips.isEmpty()) ui.click("Delete");
            assertEquals("Deleting every timeline instance does not delete the source pool", 2, ui.project().assets.size());
            assertEquals(2, ui.project().sources().size());
            for (File media : ownedMedia) assertTrue("Source file is retained after timeline deletion", media.isFile());
            ui.openPanel("mediaPanel", "Media", "Media Pool");
            ui.assertPanelShown("mediaPanel");
            ui.capture("media-pool-retained");
            ui.clickWithin(ui.panel("mediaPanel"), "Add all");
            assertEquals("Pool Add all creates fresh full-source native timeline instances", 2, ui.project().clips.size());
            ui.closeCompactDialog();
            ui.click("Undo"); assertTrue(ui.project().clips.isEmpty());
            ui.click("Redo"); assertEquals(2, ui.project().clips.size());
            ui.click("Fit"); ui.tapTimeline(600, false);

            ui.openWorkspace("Effects", "Motion/Effects");
            ui.edit("Scale %", "125.0", true);
            ui.edit("Rotation °", "15.0", true);
            ui.edit("Position X %", "20.0", true);
            ui.edit("Position Y %", "15.0", true);
            ui.edit("Opacity %", "80.0", true);
            ui.scrollInspectorToTop(); ui.capture("motion-effects");
            // Native in-panel tab navigation must not create a stack of empty modal dialogs.
            ui.clickWithin(ui.panel("inspectorPanel"), "Colour");
            ui.assertGradeDisplay("Contrast %", 100f);
            ui.edit("Brightness %", "25.0", true);
            ui.edit("Contrast %", "80.0", true);
            ui.edit("Saturation %", "60.0", true);
            ui.scrollInspectorToTop(); ui.capture("colour");
            ui.closeCompactDialog();
            ui.click("Undo"); assertEquals(1f, ui.project().clips.get(0).settings.saturation, 0.0001f);
            ui.click("Redo"); assertEquals(0.6f, ui.project().clips.get(0).settings.saturation, 0.0001f);
            ui.drainActivityIo();
            StudioProject saved = files.loadDraft();
            StudioProject.ClipSettings settings = saved.clips.get(0).settings;
            assertEquals(1.25f, settings.scale, 0.0001f); assertEquals(15f, settings.rotationDegrees, 0.0001f);
            assertEquals(0.2f, settings.positionX, 0.0001f); assertEquals(0.15f, settings.positionY, 0.0001f);
            assertEquals(0.8f, settings.opacity, 0.0001f); assertEquals(0.25f, settings.brightness, 0.0001f);
            assertEquals("80 percent is the actual contrast factor, not a normalized adjustment", -0.1110667f,
                    settings.contrast, 0.000001f); assertEquals(0.6f, settings.saturation, 0.0001f);
            assertEquals("Other source instance keeps default inspector values", 1f, saved.clips.get(1).settings.scale, 0f);
            assertEquals(2, saved.assets.size());

            // Verify focus/blur commits through native navigation, not a direct model write.
            ui.openWorkspace("Effects", "Motion/Effects");
            ui.edit("Scale %", "135.0", false);
            ui.closeCompactDialog();
            ui.click("Home");
            assertEquals("Leaving the workspace commits the focused native numeric control", 1.35f,
                    ui.project().clips.get(0).settings.scale, 0.0001f);
            ui.click("Continue edit"); ui.waitPreview(); ui.click("Fit");
            ui.assertEditorLayout(); ui.assertGraphicalTimeline(); ui.capture("editor-edited");
            ui.checkOtherActivityOrientation();
            ui.drainActivityIo();
            assertEquals("Motion survives window rebuild and actual private autosave", 1.35f,
                    files.loadDraft().clips.get(0).settings.scale, 0.0001f);
            Log.i("NetVistaNativeUiChecks", "PASS: real Studio Home artwork, native adaptive panels, graphical timeline scrub/split/duplicate/delete/pool Add/Undo/Redo, inspector commit/autosave and device screenshots");
        } finally {
            try { if (ui != null) ui.close(); }
            finally {
                restoreDraft(draft, originalDraft);
                for (File file : ownedMedia) file.delete();
                File[] temporary = scratch.listFiles();
                if (temporary != null) for (File file : temporary) file.delete();
                scratch.delete();
            }
        }
    }

    private static StudioProject fixtureProject(Instrumentation instrumentation, ProjectFiles files,
                                               File scratch, List<File> owned) throws Exception {
        StudioProject project = new StudioProject(); project.title = "Native workspace QA";
        project.width = 1280; project.height = 720;
        String[] fixtureNames = {"red-silent-landscape.mp4", "blue-audio-portrait.mp4"};
        String[] clipNames = {"QA Red landscape", "QA Blue portrait"};
        for (int index = 0; index < fixtureNames.length; index++) {
            File fixture = new File(scratch, fixtureNames[index]);
            try (InputStream input = instrumentation.getContext().getAssets().open("export-fixtures/" + fixtureNames[index]);
                 FileOutputStream output = new FileOutputStream(fixture)) {
                ProjectFiles.copy(input, output, 1024 * 1024);
            }
            String sourceId = UUID.randomUUID().toString();
            File media = files.importVideo(Uri.fromFile(fixture), sourceId); owned.add(media);
            MediaMetadataRetriever metadata = new MediaMetadataRetriever(); long duration;
            try {
                metadata.setDataSource(media.getAbsolutePath());
                String value = metadata.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
                assertNotNull(value); duration = Long.parseLong(value);
            } finally { metadata.release(); }
            assertTrue(duration >= 2500);
            String uri = "media/" + sourceId + ".video";
            project.assets.add(new StudioProject.Clip(sourceId, uri, clipNames[index], duration, 0, duration));
            project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), uri, clipNames[index], duration,
                    index == 0 ? 0 : 300, index == 0 ? 2400 : 2500,
                    index == 0 ? new StudioProject.ClipSettings() : new StudioProject.ClipSettings(1, 0, 0, 0, 1, 0, 1, 1)));
        }
        return project;
    }

    private static byte[] readExistingDraft(AtomicFile draft) throws Exception {
        if (!draft.getBaseFile().exists() && !new File(draft.getBaseFile().getPath() + ".bak").exists()) return null;
        try (InputStream input = draft.openRead(); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            ProjectFiles.copy(input, output, 16 * 1024 * 1024); return output.toByteArray();
        }
    }

    private static void restoreDraft(AtomicFile draft, byte[] original) throws Exception {
        if (original == null) { draft.delete(); return; }
        FileOutputStream output = null;
        try { output = draft.startWrite(); output.write(original); draft.finishWrite(output); }
        catch (Exception failure) { if (output != null) draft.failWrite(output); throw failure; }
    }

    private interface Condition { boolean ready() throws Exception; }
    private static void waitUntil(String message, long timeoutMs, Condition condition) throws Exception {
        long deadline = SystemClock.elapsedRealtime() + timeoutMs;
        boolean ready = condition.ready();
        while (!ready && SystemClock.elapsedRealtime() < deadline) { SystemClock.sleep(40); ready = condition.ready(); }
        assertTrue(message, ready);
    }

    private static Object field(Object object, String name) throws Exception {
        Field value = object.getClass().getDeclaredField(name); value.setAccessible(true); return value.get(object);
    }
    private static void setField(Object object, String name, Object value) throws Exception {
        Field member = object.getClass().getDeclaredField(name); member.setAccessible(true); member.set(object, value);
    }
    private static View findDescription(View root, String description) {
        if (description.contentEquals(root.getContentDescription() == null ? "" : root.getContentDescription())) return root;
        if (root instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) root;
            for (int index = 0; index < group.getChildCount(); index++) {
                View found = findDescription(group.getChildAt(index), description); if (found != null) return found;
            }
        }
        return null;
    }
    private static Button findButton(View root, String text) {
        if (root instanceof Button && text.contentEquals(((Button) root).getText()) && root.isShown()) return (Button) root;
        if ("Home".equals(text) && root instanceof Button && "Studio Home".contentEquals(
                root.getContentDescription() == null ? "" : root.getContentDescription()) && root.isShown()) return (Button) root;
        if (root instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) root;
            for (int index = 0; index < group.getChildCount(); index++) {
                Button found = findButton(group.getChildAt(index), text); if (found != null) return found;
            }
        }
        return null;
    }

    private static final class Harness {
        final Instrumentation instrumentation;
        final Context context;
        final MainActivity activity;
        final int originalOrientation;
        StudioAccount account;
        StudioAccount.Snapshot originalSnapshot;

        Harness(Instrumentation instrumentation, Context context, MainActivity activity) {
            this.instrumentation = instrumentation; this.context = context; this.activity = activity;
            originalOrientation = activity.getRequestedOrientation();
        }
        <T> T main(Callable<T> task) throws Exception {
            AtomicReference<T> value = new AtomicReference<>(); AtomicReference<Throwable> error = new AtomicReference<>();
            instrumentation.runOnMainSync(() -> { try { value.set(task.call()); } catch (Throwable failure) { error.set(failure); } });
            if (error.get() != null) {
                Throwable failure = error.get();
                if (failure instanceof Exception) throw (Exception) failure;
                if (failure instanceof Error) throw (Error) failure;
                throw new AssertionError(failure);
            }
            return value.get();
        }
        View root() { return activity.getWindow().getDecorView(); }
        View panel(String name) throws Exception { return main(() -> (View) field(activity, name)); }
        StudioProject project() throws Exception { return main(() -> ((StudioProject) field(activity, "project")).copy()); }
        void installInMemoryTestSnapshot(StudioAccount account) throws Exception {
            this.account = account; originalSnapshot = account.state();
            StudioAccount.Snapshot verified = new StudioAccount.Snapshot(true, false, "native-ui@example.invalid", "Native UI QA — memory-only snapshot");
            main(() -> {
                // Production entry gates re-read state(); this changes only the test process value,
                // never the encrypted session, user record, lastVerified timestamp or provider.
                ((Handler) field(activity, "main")).removeCallbacks((Runnable) field(activity, "accountTimer"));
                setField(account, "snapshot", verified);
                Method method = MainActivity.class.getDeclaredMethod("accountChanged", StudioAccount.Snapshot.class);
                method.setAccessible(true); method.invoke(activity, verified); return null;
            });
            instrumentation.waitForIdleSync();
        }
        void reveal(View view) throws Exception {
            assertNotNull(view);
            main(() -> { view.requestRectangleOnScreen(new Rect(0, 0, view.getWidth(), view.getHeight()), true); return null; });
            instrumentation.waitForIdleSync();
        }
        void click(String text) throws Exception { clickWithin(main(this::root), text); }
        void clickWithin(View parent, String text) throws Exception {
            Button button = main(() -> findButton(parent, text)); assertNotNull("Native button exists: " + text, button);
            reveal(button);
            main(() -> {
                assertTrue("Native button is enabled: " + text, button.isEnabled());
                assertTrue("Native button is visible: " + text, button.getGlobalVisibleRect(new Rect()));
                assertTrue("Real native click handler runs: " + text, button.performClick()); return null;
            });
            instrumentation.waitForIdleSync();
        }
        void clickAccessibleText(String text) throws Exception {
            waitUntil("Native dialog item is accessible: " + text, 3000, () -> {
                AccessibilityNodeInfo root = instrumentation.getUiAutomation().getRootInActiveWindow();
                if (root == null) return false;
                assertEquals("Only operate the instrumented app's native window", context.getPackageName(), String.valueOf(root.getPackageName()));
                List<AccessibilityNodeInfo> nodes = root.findAccessibilityNodeInfosByText(text);
                for (AccessibilityNodeInfo node : nodes) {
                    // Framework Material dialog buttons render their action titles
                    // in all caps; accessibility may therefore report CLOSE.
                    // Still require the exact action label and our app's window.
                    if (!text.equalsIgnoreCase(node.getText() == null ? "" : node.getText().toString())) continue;
                    AccessibilityNodeInfo clickable = node;
                    while (clickable != null && !clickable.isClickable()) clickable = clickable.getParent();
                    if (clickable != null && clickable.isEnabled() && clickable.performAction(AccessibilityNodeInfo.ACTION_CLICK)) return true;
                }
                return false;
            });
            instrumentation.waitForIdleSync();
        }
        boolean shortWindow() throws Exception { return main(() -> activity.getResources().getConfiguration().screenHeightDp < 500); }
        boolean wide() throws Exception { return main(() -> (Boolean) field(activity, "wideLayout")); }
        void openPanel(String name, String compactButton, String overflowItem) throws Exception {
            if (wide()) return;
            closeCompactDialog();
            Button toggle = main(() -> findButton(root(), compactButton));
            if (toggle != null) click(compactButton);
            else { click("⋮"); clickAccessibleText(overflowItem); }
            waitUntil("Native panel is visible: " + name, 3000, () -> main(() -> ((View) field(activity, name)).isShown()));
        }
        void openWorkspace(String button, String overflowItem) throws Exception {
            closeCompactDialog();
            Button navigation = main(() -> findButton(root(), button));
            if (navigation != null) click(button);
            else { click("⋮"); clickAccessibleText(overflowItem); }
            assertPanelShown("inspectorPanel");
        }
        void closeCompactDialog() throws Exception {
            boolean showing = main(() -> {
                Object value = field(activity, "compactDialog"); return value instanceof android.app.Dialog && ((android.app.Dialog) value).isShowing();
            });
            if (showing) {
                main(() -> {
                    android.app.AlertDialog dialog = (android.app.AlertDialog) field(activity, "compactDialog");
                    Button close = dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE);
                    assertNotNull("Compact panel has a real native Close button", close);
                    Rect visible = new Rect();
                    assertTrue("Compact panel Close is visibly reachable in the available window", close.getGlobalVisibleRect(visible));
                    assertTrue("Compact panel Close retains a usable native touch target", visible.width() >= close.getWidth() - 1 && visible.height() >= close.getHeight() - 1);
                    return null;
                });
                try { clickAccessibleText("Close"); }
                catch (AssertionError failure) { capture("close-dialog-failure"); throw failure; }
                instrumentation.waitForIdleSync();
            }
        }
        void assertPanelShown(String name) throws Exception {
            main(() -> { View panel = (View) field(activity, name); assertTrue(name + " is a real attached native panel", panel.isShown());
                Rect rectangle = new Rect(); assertTrue(name + " has visible available-window bounds", panel.getGlobalVisibleRect(rectangle));
                assertTrue(rectangle.width() > 50 && rectangle.height() > 50); inspectControls(panel); return null; });
        }
        void waitPreview() throws Exception {
            waitUntil("CompositionPlayer prepares the real local native preview", 12000, () -> main(() -> {
                CompositionPlayer player = (CompositionPlayer) field(activity, "player");
                return player != null && player.getPlaybackState() == Player.STATE_READY && player.getPlayerError() == null;
            }));
        }
        void drainActivityIo() throws Exception {
            ExecutorService io = main(() -> (ExecutorService) field(activity, "io")); io.submit(() -> {}).get(15, TimeUnit.SECONDS);
            instrumentation.waitForIdleSync();
        }
        void tapTimeline(long positionMs, boolean ruler) throws Exception {
            click("Fit");
            float[] point = main(() -> {
                StudioTimelineView timeline = (StudioTimelineView) field(activity, "timeline");
                float density = activity.getResources().getDisplayMetrics().density;
                Rect bounds = new Rect(); assertTrue(timeline.getGlobalVisibleRect(bounds));
                long duration = ((StudioProject) field(activity, "project")).durationMs();
                float x = bounds.left + 66 * density + (timeline.getWidth() - 78 * density) * positionMs / duration;
                float y = bounds.top + (ruler ? 14 : 48) * density;
                return new float[]{x, Math.min(bounds.bottom - 2, y)};
            });
            long down = SystemClock.uptimeMillis();
            MotionEvent press = MotionEvent.obtain(down, down, MotionEvent.ACTION_DOWN, point[0], point[1], 0);
            MotionEvent release = MotionEvent.obtain(down, down + 60, MotionEvent.ACTION_UP, point[0], point[1], 0);
            try { instrumentation.sendPointerSync(press); SystemClock.sleep(60); instrumentation.sendPointerSync(release); }
            finally { press.recycle(); release.recycle(); }
            instrumentation.waitForIdleSync();
            waitUntil("Graphical timeline changes the actual sequence playhead", 3000,
                    () -> main(() -> Math.abs((Long) field(activity, "playheadMs") - positionMs) < 150));
        }
        void edit(String description, String text, boolean done) throws Exception {
            View inspector = panel("inspectorPanel");
            EditText value = main(() -> (EditText) findDescription(inspector, description));
            assertNotNull("Native inspector field: " + description, value); reveal(value);
            main(() -> { assertTrue(value.isEnabled()); value.requestFocus(); value.setText(text);
                if (done) value.onEditorAction(EditorInfo.IME_ACTION_DONE); return null; });
            instrumentation.waitForIdleSync();
        }
        void assertGradeDisplay(String description, float expected) throws Exception {
            EditText value = main(() -> (EditText) findDescription((View) field(activity, "inspectorPanel"), description));
            assertNotNull("Native grade field exists: " + description, value);
            assertEquals("Native displayed grade: " + description, expected,
                    main(() -> Float.parseFloat(value.getText().toString())), 0f);
        }
        void scrollInspectorToTop() throws Exception {
            main(() -> {
                View parent = ((View) field(activity, "inspector")).getParent() instanceof View
                        ? (View) ((View) field(activity, "inspector")).getParent() : null;
                if (parent instanceof ScrollView) ((ScrollView) parent).scrollTo(0, 0); return null;
            });
            instrumentation.waitForIdleSync();
        }
        void assertCompactNativeControls(View root) throws Exception {
            main(() -> { inspectControls(root); return null; });
        }
        private void inspectControls(View view) {
            assertFalse("The workspace must be native, never a WebView", view instanceof WebView);
            Rect visible = new Rect();
            if (view.isShown() && view.getGlobalVisibleRect(visible)) {
                float density = view.getResources().getDisplayMetrics().density;
                float scaled = view.getResources().getDisplayMetrics().scaledDensity;
                if (view instanceof Button) {
                    Button button = (Button) view;
                    assertTrue("Visible native button is at least 44dp wide: " + button.getText(), button.getWidth() + 1 >= 44 * density);
                    assertTrue("Visible native button is at least 44dp tall: " + button.getText(), button.getHeight() + 1 >= 44 * density);
                    assertEquals("Short native button labels must not wrap: " + button.getText(), 1, button.getMaxLines());
                    boolean transportSymbol = "Play or pause".contentEquals(button.getContentDescription() == null ? "" : button.getContentDescription())
                            || "⌂".contentEquals(button.getText());
                    if (!transportSymbol) {
                        assertTrue("Compact native button title: " + button.getText(), button.getTextSize() / scaled <= 13.1f);
                    }
                } else if (view instanceof TextView) {
                    TextView text = (TextView) view; String label = text.getText().toString();
                    boolean displayHeading = "NetVista".equals(label) || "Studio Home".equals(label)
                            || "Video editing workspace".equals(label) || "▣".equals(label);
                    if (!displayHeading) assertTrue("Compact native body/property font: " + label, text.getTextSize() / scaled <= 13.1f);
                }
            }
            if (view instanceof ViewGroup) {
                ViewGroup group = (ViewGroup) view; for (int index = 0; index < group.getChildCount(); index++) inspectControls(group.getChildAt(index));
            }
        }
        void assertEditorLayout() throws Exception {
            assertTrue(main(() -> (Boolean) field(activity, "editorVisible")));
            assertPanelShown("monitorPanel"); assertCompactNativeControls(main(this::root));
            main(() -> {
                StudioTimelineView timeline = (StudioTimelineView) field(activity, "timeline");
                assertTrue(timeline.isShown()); assertTrue(timeline.getWidth() > 100 && timeline.getHeight() > 30);
                // Inspect the same native draw geometry used onDraw, including short landscape.
                Method lane = StudioTimelineView.class.getDeclaredMethod("laneHeight"); lane.setAccessible(true);
                Method ruler = StudioTimelineView.class.getDeclaredMethod("rulerHeight"); ruler.setAccessible(true);
                float drawnHeight = (Float) ruler.invoke(timeline) + 2 * (Float) lane.invoke(timeline);
                assertTrue("Both native V1/A1 lanes fit the actual timeline window", drawnHeight <= timeline.getHeight() + 1);
                return null;
            });
            if (wide()) {
                assertPanelShown("mediaPanel"); assertPanelShown("inspectorPanel");
                main(() -> {
                    Rect media = new Rect(), monitor = new Rect(), inspector = new Rect();
                    ((View) field(activity, "mediaPanel")).getGlobalVisibleRect(media);
                    ((View) field(activity, "monitorPanel")).getGlobalVisibleRect(monitor);
                    ((View) field(activity, "inspectorPanel")).getGlobalVisibleRect(inspector);
                    assertTrue("Wide native layout is Media | Monitor | Inspector", media.right <= monitor.left + 1 && monitor.right <= inspector.left + 1);
                    assertEquals(media.top, monitor.top); assertEquals(monitor.top, inspector.top); return null;
                });
            } else {
                openPanel("mediaPanel", "Media", "Media Pool"); assertPanelShown("mediaPanel"); closeCompactDialog();
                openPanel("inspectorPanel", "Inspector", "Inspector"); assertPanelShown("inspectorPanel"); closeCompactDialog();
                if (!shortWindow()) click("Monitor");
                assertPanelShown("monitorPanel");
            }
        }
        void assertGraphicalTimeline() throws Exception {
            instrumentation.waitForIdleSync();
            Rect bounds = main(() -> { Rect value = new Rect(); assertTrue(((View) field(activity, "timeline")).getGlobalVisibleRect(value)); return value; });
            Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot(); assertNotNull(screenshot);
            if (screenshot.getConfig() == Bitmap.Config.HARDWARE) {
                Bitmap readable = screenshot.copy(Bitmap.Config.ARGB_8888, false); screenshot.recycle(); screenshot = readable;
                assertNotNull("Read back native screenshot pixels", screenshot);
            }
            try {
                int blue = 0, green = 0, red = 0;
                for (int y = Math.max(0, bounds.top); y < Math.min(screenshot.getHeight(), bounds.bottom); y += 2) {
                    for (int x = Math.max(0, bounds.left); x < Math.min(screenshot.getWidth(), bounds.right); x += 2) {
                        int pixel = screenshot.getPixel(x, y);
                        if (near(pixel, 53, 111, 159)) blue++;
                        if (near(pixel, 24, 139, 116)) green++;
                        if (near(pixel, 240, 91, 94)) red++;
                    }
                }
                assertTrue("Native screenshot contains actual blue V1 clip blocks", blue > 100);
                assertTrue("Native screenshot contains actual green linked A1 clip blocks", green > 100);
                assertTrue("Native screenshot contains the red timeline playhead", red > 5);
            } finally { screenshot.recycle(); }
        }
        private static boolean near(int pixel, int red, int green, int blue) {
            return Math.abs(Color.red(pixel) - red) < 12 && Math.abs(Color.green(pixel) - green) < 12 && Math.abs(Color.blue(pixel) - blue) < 12;
        }
        void capture(String phase) throws Exception {
            instrumentation.waitForIdleSync();
            Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot(); assertNotNull("Capture actual native device screenshot", screenshot);
            try {
                File external = context.getExternalFilesDir(null); assertNotNull(external);
                File directory = new File(external, "ui-screenshots"); assertTrue(directory.isDirectory() || directory.mkdirs());
                Configuration configuration = main(() -> new Configuration(activity.getResources().getConfiguration()));
                String name = phase + "_" + configuration.screenWidthDp + "x" + configuration.screenHeightDp + "dp_"
                        + screenshot.getWidth() + "x" + screenshot.getHeight() + ".png";
                File output = new File(directory, name);
                try (FileOutputStream stream = new FileOutputStream(output)) { assertTrue(screenshot.compress(Bitmap.CompressFormat.PNG, 100, stream)); }
                Log.i("NetVistaNativeUiChecks", "Native screenshot: " + output.getAbsolutePath());
            } finally { screenshot.recycle(); }
        }
        void checkOtherActivityOrientation() throws Exception {
            int initial = main(() -> activity.getResources().getConfiguration().orientation);
            int target = initial == Configuration.ORIENTATION_LANDSCAPE ? Configuration.ORIENTATION_PORTRAIT : Configuration.ORIENTATION_LANDSCAPE;
            main(() -> { activity.setRequestedOrientation(target == Configuration.ORIENTATION_LANDSCAPE
                    ? ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE : ActivityInfo.SCREEN_ORIENTATION_PORTRAIT); return null; });
            // Android 16 large-window policies may ignore orientation requests. Inspect what the
            // Activity actually receives; do not change global emulator display state to force it.
            long deadline = SystemClock.elapsedRealtime() + 4000;
            while (main(() -> activity.getResources().getConfiguration().orientation) != target && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(50);
            instrumentation.waitForIdleSync();
            closeCompactDialog(); waitPreview(); click("Fit"); assertEditorLayout(); assertGraphicalTimeline();
            Configuration actual = main(() -> new Configuration(activity.getResources().getConfiguration()));
            capture(actual.orientation == Configuration.ORIENTATION_LANDSCAPE ? "editor-landscape" : "editor-portrait");
            if (actual.screenHeightDp < 500) {
                openPanel("inspectorPanel", "Inspector", "Inspector"); assertPanelShown("inspectorPanel");
                clickWithin(panel("inspectorPanel"), "Motion"); clickWithin(panel("inspectorPanel"), "Colour");
                assertPanelShown("inspectorPanel"); capture("short-window-inspector"); closeCompactDialog();
                assertTrue("Closing short Inspector returns to the actual native editor", main(() -> root().hasWindowFocus()));
            }
            Log.i("NetVistaNativeUiChecks", "Actual available window: " + actual.screenWidthDp + "x" + actual.screenHeightDp
                    + "dp; orientation request " + (actual.orientation == target ? "honored" : "ignored by platform") + "; wide=" + wide());
        }
        void close() throws Exception {
            main(() -> { activity.setRequestedOrientation(originalOrientation); activity.finish(); return null; });
            try {
                waitUntil("Activity is destroyed before restoring isolated test state", 10000, () -> main(activity::isDestroyed));
                ExecutorService io = (ExecutorService) field(activity, "io");
                assertTrue("All Activity autosaves finish before restoring the original draft", io.awaitTermination(15, TimeUnit.SECONDS));
            } finally {
                if (account != null && originalSnapshot != null) main(() -> { setField(account, "snapshot", originalSnapshot); return null; });
            }
        }
    }
}
