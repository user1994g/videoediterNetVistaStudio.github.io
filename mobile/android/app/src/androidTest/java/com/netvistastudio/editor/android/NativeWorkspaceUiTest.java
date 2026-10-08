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
import android.view.InputDevice;
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
import androidx.media3.common.PlaybackException;
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
    // This end-to-end scenario captures 20+ real composited device screenshots.
    // Software-GPU bitmap readback can consume substantial CI wall-clock time
    // after native controls/render checks have already passed. This is a global
    // capture budget, not a responsiveness benchmark: individual preview/seek
    // checks remain bounded at 12s and actual rendered-pixel oracles at 3s.
    @Test(timeout = 600000)
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
            ui.assertErroredPreviewRecovery();

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
            ui.assertEmptyMonitor();
            ui.openPanel("mediaPanel", "Media", "Media Pool");
            ui.assertPanelShown("mediaPanel");
            ui.capture("media-pool-retained");
            ui.clickWithin(ui.panel("mediaPanel"), "Add all");
            assertEquals("Pool Add all creates fresh full-source native timeline instances", 2, ui.project().clips.size());
            ui.closeCompactDialog();
            ui.click("Undo"); assertTrue(ui.project().clips.isEmpty());
            ui.click("Redo"); assertEquals(2, ui.project().clips.size());
            ui.click("Fit"); ui.tapTimeline(600, true);

            ui.openWorkspace("Effects", "Motion/Effects");
            // A native numeric edit has not sent Done/blur yet. Mutating the
            // timeline must commit it before copying clips or replacing history,
            // rather than losing it when the inspector's old view is removed.
            ui.edit("Scale %", "140.0", false);
            ui.click("Duplicate");
            StudioProject pendingDuplicate = ui.project();
            assertEquals(3, pendingDuplicate.clips.size());
            assertEquals("Duplicate commits the pending original scale", 1.4f, pendingDuplicate.clips.get(0).settings.scale, 0.0001f);
            assertEquals("New independent instance copies the committed scale", 1.4f, pendingDuplicate.clips.get(1).settings.scale, 0.0001f);
            ui.click("Undo");
            assertEquals(2, ui.project().clips.size());
            assertEquals("Undo duplicate retains its preceding committed field edit", 1.4f, ui.project().clips.get(0).settings.scale, 0.0001f);
            ui.click("Undo");
            assertEquals("Second Undo reverses the numeric commit independently", 1f, ui.project().clips.get(0).settings.scale, 0.0001f);
            ui.click("Redo"); ui.click("Redo");
            assertEquals(3, ui.project().clips.size());
            assertEquals(1.4f, ui.project().clips.get(1).settings.scale, 0.0001f);
            ui.click("Undo"); ui.click("Undo");
            assertEquals(2, ui.project().clips.size());
            assertEquals(1f, ui.project().clips.get(0).settings.scale, 0.0001f);
            ui.waitPreview();
            CompositionPlayer effectEditingPlayer = ui.main(() -> (CompositionPlayer) field(activity, "player"));
            ui.edit("Scale %", "125.0", true);
            ui.edit("Rotation °", "15.0", true);
            ui.edit("Position X %", "20.0", true);
            ui.edit("Position Y %", "15.0", true);
            ui.edit("Opacity %", "80.0", true);
            // Short phone windows use a native modal Inspector. Dismiss its
            // opaque/dimmed surface before sampling the actual monitor, then
            // reopen it for the controls screenshot and in-panel navigation.
            ui.closeCompactDialog();
            ui.waitPreview();
            ui.assertMotionPreview();
            assertSame("Motion-only editing redraws the existing real native player, not a replacement graph",
                    effectEditingPlayer, ui.main(() -> (CompositionPlayer) field(activity, "player")));
            ui.capture("motion-preview");
            ui.openWorkspace("Effects", "Motion/Effects");
            ui.scrollInspectorToTop(); ui.capture("motion-effects");
            // Runtime matrix stages must still exist when initially neutral.
            // Change the paused frame to fully transparent and back via
            // native history without rebuilding or seeking the media decoder.
            ui.edit("Opacity %", "0.0", true);
            ui.closeCompactDialog(); ui.waitPreview(); ui.assertOpacityZeroPreview();
            assertSame("Paused opacity zero redraws the same native player",
                    effectEditingPlayer, ui.main(() -> (CompositionPlayer) field(activity, "player")));
            ui.capture("motion-opacity-zero");
            ui.click("Undo");
            assertEquals("Native Undo restores the preceding opacity", 0.8f, ui.project().clips.get(0).settings.opacity, 0.0001f);
            ui.waitPreview(); ui.assertMotionPreview();
            assertSame("Opacity Undo redraws the same native player",
                    effectEditingPlayer, ui.main(() -> (CompositionPlayer) field(activity, "player")));
            ui.openWorkspace("Effects", "Motion/Effects");
            // Native in-panel tab navigation must not create a stack of empty modal dialogs.
            ui.clickWithin(ui.panel("inspectorPanel"), "Colour");
            ui.assertGradeDisplay("Contrast %", 100f);
            ui.edit("Brightness %", "25.0", true);
            ui.edit("Contrast %", "80.0", true);
            ui.edit("Saturation %", "60.0", true);
            ui.closeCompactDialog();
            ui.waitPreview();
            ui.assertColourPreview();
            assertSame("Colour-only editing redraws the same real native player",
                    effectEditingPlayer, ui.main(() -> (CompositionPlayer) field(activity, "player")));
            ui.capture("colour-preview");
            ui.openWorkspace("Colour", "Colour");
            ui.scrollInspectorToTop(); ui.capture("colour");
            ui.closeCompactDialog();
            ui.click("Undo"); assertEquals(1f, ui.project().clips.get(0).settings.saturation, 0.0001f);
            ui.click("Redo"); assertEquals(0.6f, ui.project().clips.get(0).settings.saturation, 0.0001f);
            ui.waitPreview();
            ui.assertColourPreview();
            assertSame("Colour Undo/Redo preserves native player identity when timeline topology is unchanged",
                    effectEditingPlayer, ui.main(() -> (CompositionPlayer) field(activity, "player")));
            ui.assertPreviewAfterSdkStop();
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

            // Exercise actual native animation controls and decoded paused
            // surface pixels, not direct model writes or a mock effect graph.
            ui.tapTimeline(600, true);
            ui.openWorkspace("Effects", "Motion/Effects"); ui.click("◆ Animation / keyframes");
            ui.click("◆ Add / update keyframe");
            ClipAnimation.Keyframe firstKey = ui.project().clips.get(0).animation.points(ClipAnimation.Property.OPACITY).get(0);
            assertEquals(.8f, firstKey.value, .0001f);
            ui.closeCompactDialog(); ui.tapTimeline(1200, true);
            ui.openWorkspace("Effects", "Motion/Effects"); ui.click("◆ Animation / keyframes");
            ui.edit("Opacity %", "0.0", true); ui.closeCompactDialog(); ui.waitPreview(); ui.assertOpacityZeroPreview();
            List<ClipAnimation.Keyframe> nativeKeys = ui.project().clips.get(0).animation.points(ClipAnimation.Property.OPACITY);
            assertEquals(2, nativeKeys.size()); assertEquals(0, nativeKeys.get(1).value, 0);
            assertEquals("Animated edits retain the fallback setting", .8f, ui.project().clips.get(0).settings.opacity, .0001f);
            assertSame("Keyframe creation redraws the existing decoder", effectEditingPlayer,
                    ui.main(() -> (CompositionPlayer) field(activity, "player")));
            long midpoint = (nativeKeys.get(0).sourceMs + nativeKeys.get(1).sourceMs) / 2;
            ui.tapTimeline(midpoint, true); ui.waitPreview();
            final Harness animationUi = ui;
            long actualTime = ui.main(() -> (Long) field(activity, "playheadMs"));
            float expectedRatio = (nativeKeys.get(1).sourceMs - actualTime) / (float) (nativeKeys.get(1).sourceMs - nativeKeys.get(0).sourceMs);
            waitUntil("Native seek evaluates animated opacity at the actual frame time", 3000, () -> {
                int pixel = animationUi.monitorCenterPixel();
                return Math.abs(Color.red(pixel) - 173 * expectedRatio) < 18
                        && Math.abs(Color.green(pixel) - 75 * expectedRatio) < 18
                        && Math.abs(Color.blue(pixel) - 75 * expectedRatio) < 18;
            });
            ui.openWorkspace("Effects", "Motion/Effects"); ui.click("◆ Animation / keyframes");
            ui.click("Next ◆ ▶"); assertEquals(nativeKeys.get(1).sourceMs, (long) ui.main(() -> (Long) field(activity, "playheadMs")));
            ui.click("◀ Previous ◆"); assertEquals(nativeKeys.get(0).sourceMs, (long) ui.main(() -> (Long) field(activity, "playheadMs")));
            ui.click("Curve: Linear ▾"); ui.clickAccessibleText("Hold");
            assertEquals(ClipAnimation.Curve.HOLD, ui.project().clips.get(0).animation.points(ClipAnimation.Property.OPACITY).get(0).curve);
            ui.closeCompactDialog(); ui.tapTimeline(midpoint, true); ui.waitPreview(); ui.assertColourPreview();
            ui.openWorkspace("Effects", "Motion/Effects"); ui.click("◆ Animation / keyframes");
            ui.tapAnimationDiamond(nativeKeys.get(1).sourceMs);
            assertEquals("Real drawn diamond seeks exactly", nativeKeys.get(1).sourceMs,
                    (long) ui.main(() -> (Long) field(activity, "playheadMs")));
            ui.click("Remove keyframe here"); assertEquals(1, ui.project().clips.get(0).animation.points(ClipAnimation.Property.OPACITY).size());
            ui.click("Clear this property's keys"); assertTrue(ui.project().clips.get(0).animation.isEmpty());
            ui.closeCompactDialog(); ui.waitPreview(); ui.assertColourPreview();
            ui.click("Undo"); assertEquals(1, ui.project().clips.get(0).animation.points(ClipAnimation.Property.OPACITY).size());
            ui.click("Redo"); assertTrue(ui.project().clips.get(0).animation.isEmpty());
            ui.drainActivityIo(); assertTrue(files.loadDraft().clips.get(0).animation.isEmpty());

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
        } catch (Exception | AssertionError failure) {
            if (ui != null) {
                try { ui.capture("workspace-failure"); }
                catch (Exception captureFailure) { Log.w("NetVistaNativeUiChecks", "Could not retain failure screenshot", captureFailure); }
            }
            throw failure;
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

    @Test(timeout = 180000)
    public void nativeSliderAndNumericKeyCapFailuresPreserveProjectHistoryAndRestoreControls() throws Exception {
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation(); Context context = instrumentation.getTargetContext();
        assumeTrue("Run cap regression on a clean install without saved account credentials",
                !context.getSharedPreferences("encrypted_account", Context.MODE_PRIVATE).contains("ciphertext"));
        ProjectFiles files = new ProjectFiles(context); AtomicFile draft = new AtomicFile(new File(context.getFilesDir(), "mobile-draft.json"));
        byte[] originalDraft = readExistingDraft(draft); File scratch = new File(context.getCacheDir(), "native-key-cap-" + UUID.randomUUID());
        assertTrue(scratch.mkdir()); List<File> ownedMedia = new ArrayList<>(); Harness ui = null;
        try {
            StudioProject capped = fixtureProject(instrumentation, files, scratch, ownedMedia);
            StudioProject.Clip first = capped.clips.get(0); first.settings = new StudioProject.ClipSettings(1, 0, 0, 0, .8f, 0, 0, 1);
            java.util.EnumMap<ClipAnimation.Property, List<ClipAnimation.Keyframe>> tracks = new java.util.EnumMap<>(ClipAnimation.Property.class);
            for (int propertyIndex = 0; propertyIndex < 5; propertyIndex++) {
                ClipAnimation.Property property = ClipAnimation.Property.values()[propertyIndex]; List<ClipAnimation.Keyframe> points = new ArrayList<>();
                int count = property == ClipAnimation.Property.POSITION_Y ? 1999 : 2000;
                for (int time = 0; time < count; time++) points.add(new ClipAnimation.Keyframe(time, property.value(first.settings), ClipAnimation.Curve.LINEAR));
                tracks.put(property, points);
            }
            tracks.put(ClipAnimation.Property.SATURATION, java.util.Collections.singletonList(new ClipAnimation.Keyframe(0, 1, ClipAnimation.Curve.LINEAR)));
            first.animation = new ClipAnimation(tracks); files.saveDraft(capped);
            MainActivity activity = (MainActivity) instrumentation.startActivitySync(new Intent(context, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            ui = new Harness(instrumentation, context, activity); Harness current = ui;
            waitUntil("Capped private fixture restores before account injection", 15000, () -> current.main(() -> (Boolean) field(activity, "draftReady")));
            StudioAccount account = current.main(() -> (StudioAccount) field(activity, "account"));
            ((ExecutorService) field(account, "worker")).submit(() -> {}).get(15, TimeUnit.SECONDS); instrumentation.waitForIdleSync();
            ui.installInMemoryTestSnapshot(account); ui.click("Continue edit"); ui.waitPreview(); ui.click("Fit");
            // Updating an EXISTING key at the cap is valid. Undo creates a redo
            // entry which failed edits must neither erase nor replace with noise.
            ui.openWorkspace("Colour", "Colour"); ui.edit("Saturation %", "150.0", true); ui.closeCompactDialog(); ui.waitPreview(); ui.click("Undo");
            assertEquals(1, ui.main(() -> ((java.util.ArrayDeque<?>) field(activity, "redo")).size()).intValue());
            ui.tapTimeline(2200, true); ui.waitPreview();
            String before = ProjectCodec.encode(ui.project());
            int undoSize = ui.main(() -> ((java.util.ArrayDeque<?>) field(activity, "undo")).size());
            int redoSize = ui.main(() -> ((java.util.ArrayDeque<?>) field(activity, "redo")).size());
            assertEquals(2000, ui.project().clips.get(0).animation.points(ClipAnimation.Property.OPACITY).size());
            for (String property : new String[]{"Opacity %", "Saturation %"}) {
                ui.openWorkspace(property.startsWith("Opacity") ? "Effects" : "Colour", property.startsWith("Opacity") ? "Motion/Effects" : "Colour");
                float expected = property.startsWith("Opacity") ? 80 : 100;
                ui.tapEffectSlider(property + " slider", .25f);
                ui.assertGradeDisplay(property, expected);
                assertEquals("Rejected actual slider gesture leaves exact project bytes unchanged: " + property, before, ProjectCodec.encode(ui.project()));
                assertEquals(undoSize, ui.main(() -> ((java.util.ArrayDeque<?>) field(activity, "undo")).size()).intValue());
                assertEquals(redoSize, ui.main(() -> ((java.util.ArrayDeque<?>) field(activity, "redo")).size()).intValue());
                ui.edit(property, property.startsWith("Opacity") ? "90.0" : "150.0", true);
                ui.assertGradeDisplay(property, expected);
                assertEquals("Rejected numeric commit leaves exact project bytes unchanged: " + property, before, ProjectCodec.encode(ui.project()));
                assertEquals(undoSize, ui.main(() -> ((java.util.ArrayDeque<?>) field(activity, "undo")).size()).intValue());
                assertEquals(redoSize, ui.main(() -> ((java.util.ArrayDeque<?>) field(activity, "redo")).size()).intValue());
                ui.main(() -> { assertFalse(activity.isFinishing()); assertFalse(activity.isDestroyed());
                    assertNull(((CompositionPlayer) field(activity, "player")).getPlayerError()); return null; });
                String problem = ui.main(() -> ((TextView) field(activity, "status")).getText().toString());
                assertTrue("Cap failure is explicit and recoverable", problem.contains("keyframes"));
            }
            ui.closeCompactDialog(); ui.drainActivityIo(); assertEquals(before, ProjectCodec.encode(files.loadDraft()));
        } finally {
            try { if (ui != null) ui.close(); }
            finally { restoreDraft(draft, originalDraft); for (File file : ownedMedia) file.delete();
                File[] temporary = scratch.listFiles(); if (temporary != null) for (File file : temporary) file.delete(); scratch.delete(); }
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
                waitUntil("Native compact dialog is dismissed and editor regains window focus", 3000,
                        () -> main(() -> {
                            Object value = field(activity, "compactDialog");
                            boolean dismissed = !(value instanceof android.app.Dialog) || !((android.app.Dialog) value).isShowing();
                            return dismissed && root().hasWindowFocus();
                        }));
            }
        }
        void assertPanelShown(String name) throws Exception {
            main(() -> { View panel = (View) field(activity, name); assertTrue(name + " is a real attached native panel", panel.isShown());
                Rect rectangle = new Rect(); assertTrue(name + " has visible available-window bounds", panel.getGlobalVisibleRect(rectangle));
                assertTrue(rectangle.width() > 50 && rectangle.height() > 50); inspectControls(panel); return null; });
        }
        void waitPreview() throws Exception {
            try {
                waitUntil("CompositionPlayer prepares the latest real local native preview", 12000, () -> main(() -> {
                    CompositionPlayer player = (CompositionPlayer) field(activity, "player");
                    return !(Boolean) field(activity, "previewPending") && player != null
                            && player.getPlaybackState() == Player.STATE_READY && player.getPlayerError() == null;
                }));
            } catch (AssertionError failure) {
                String diagnostics = main(() -> {
                    CompositionPlayer player = (CompositionPlayer) field(activity, "player");
                    return "pending=" + field(activity, "previewPending") + "; clips=" + ((StudioProject) field(activity, "project")).clips.size()
                            + "; requested=" + field(activity, "playheadMs") + "; player=" + (player == null ? "null"
                            : "state=" + player.getPlaybackState() + ", position=" + player.getCurrentPosition()
                            + ", error=" + describePlaybackError(player.getPlayerError()));
                });
                Log.e("NetVistaNativeUiChecks", "Preview failure: " + diagnostics);
                throw new AssertionError(failure.getMessage() + "; " + diagnostics, failure);
            }
        }
        String describePlaybackError(PlaybackException error) {
            if (error == null) return "none";
            StringBuilder detail = new StringBuilder(error.getErrorCodeName()).append("(").append(error.errorCode).append(")");
            Throwable cause = error;
            for (int depth = 0; cause != null && depth < 6; depth++, cause = cause.getCause()) {
                detail.append(" -> ").append(cause.getClass().getName()).append(": ").append(cause.getMessage());
                // ExoTimeoutException exposes which operation actually timed
                // out. Preserve that pinned SDK diagnostic without adding a
                // production dependency or assuming all errors are decode ones.
                try { detail.append(" [timeoutOperation=").append(cause.getClass().getField("timeoutOperation").get(cause)).append("]"); }
                catch (ReflectiveOperationException | SecurityException ignored) { }
            }
            return detail.toString();
        }
        // Arm before native Play; observe on its main looper and pause through
        // the real transport as soon as playback begins, not after UI idle.
        final class PreviewPlaybackObserver implements Runnable, Player.Listener {
            final Handler handler = new Handler(Looper.getMainLooper());
            final long deadline = SystemClock.elapsedRealtime() + 15000;
            final CompositionPlayer excluded;
            final Button pauseButton;
            CompositionPlayer recovered;
            long firstReadyPosition = -1, firstPlayingPosition = -1, positionAtPause = -1;
            long playbackStartedAtMs = -1, pauseElapsedMs = -1;
            boolean observedPlaying, pressedPause;
            Throwable failure;
            PreviewPlaybackObserver(CompositionPlayer excluded, Button pauseButton) {
                this.excluded = excluded; this.pauseButton = pauseButton;
            }
            @Override public void run() {
                try {
                    if (pressedPause) return;
                    if (SystemClock.elapsedRealtime() >= deadline) throw new AssertionError("Native Play did not produce a running engine");
                    CompositionPlayer current = (CompositionPlayer) field(activity, "player");
                    if (current != null && current != excluded && current != recovered) {
                        if (recovered != null) recovered.removeListener(this);
                        recovered = current; firstReadyPosition = -1; firstPlayingPosition = -1;
                        current.addListener(this); observeReady();
                        // A callback may already be queued when this observer
                        // attaches; catch up after native notifications finish.
                        if (current.isPlaying()) handler.post(this::observePlaying);
                    }
                    handler.postDelayed(this, 10);
                } catch (Throwable error) { failure = error; }
            }
            @Override public void onPlaybackStateChanged(int state) { if (state == Player.STATE_READY) observeReady(); }
            @Override public void onIsPlayingChanged(boolean playing) { if (playing) observePlaying(); }
            void observeReady() {
                try {
                    if (recovered == null || recovered.getPlayerError() != null
                            || recovered.getPlaybackState() != Player.STATE_READY) return;
                    if (firstReadyPosition < 0) firstReadyPosition = recovered.getCurrentPosition();
                } catch (Throwable error) { failure = error; }
            }
            void observePlaying() {
                try {
                    if (recovered == null || recovered.getPlayerError() != null
                            || recovered.getPlaybackState() != Player.STATE_READY) return;
                    observeReady();
                    if (recovered.isPlaying() && !observedPlaying) {
                        firstPlayingPosition = recovered.getCurrentPosition(); observedPlaying = true;
                        playbackStartedAtMs = SystemClock.elapsedRealtime();
                        assertEquals("Running engine updates its real native transport", "Ⅱ", pauseButton.getText().toString());
                        assertTrue("Real native Pause is enabled", pauseButton.isEnabled());
                        // Run after the current SDK notification rather than
                        // modifying playback state in its listener dispatch.
                        CompositionPlayer running = recovered;
                        handler.post(() -> {
                            try {
                                CompositionPlayer current = (CompositionPlayer) field(activity, "player");
                                assertSame("Native Pause targets the observed current engine", running, current);
                                assertSame("Observer still tracks that engine", running, recovered);
                                // A posted native action may naturally run after
                                // more frames. Compare Pause with the real head
                                // immediately before its handler, not with the
                                // earlier first-playing event's timestamp.
                                positionAtPause = current.getCurrentPosition();
                                pauseElapsedMs = SystemClock.elapsedRealtime() - playbackStartedAtMs;
                                pressedPause = pauseButton.performClick();
                            }
                            catch (Throwable error) { failure = error; }
                        });
                    }
                } catch (Throwable error) { failure = error; }
            }
            void close() { handler.removeCallbacksAndMessages(null); if (recovered != null) recovered.removeListener(this); }
        }
        void playAndPausePreview(PreviewPlaybackObserver observer) throws Exception {
            main(() -> { observer.handler.post(observer); return null; });
            try {
                click("▶");
                waitPreview();
                waitUntil("Native Play reaches actual running decode and real native Pause", 3000,
                        () -> main(() -> {
                            if (observer.failure != null) throw new AssertionError("Native playback observer failed", observer.failure);
                            CompositionPlayer current = (CompositionPlayer) field(activity, "player");
                            return observer.recovered == current && current != observer.excluded && observer.observedPlaying
                                    && observer.pressedPause && current.getPlayerError() == null && !current.isPlaying();
                        }));
            } finally { main(() -> { observer.close(); return null; }); }
        }
        void assertPreviewAfterSdkStop() throws Exception {
            String preserved = ProjectCodec.encode(project());
            long requested = main(() -> (Long) field(activity, "playheadMs"));
            CompositionPlayer stopped = main(() -> (CompositionPlayer) field(activity, "player"));
            main(() -> {
                // This is the SDK stop/IDLE transition used by export, NOT an
                // assertion that the full Files/export dialog was exercised.
                stopped.stop(); assertEquals(Player.STATE_IDLE, stopped.getPlaybackState());
                assertNull(stopped.getPlayerError()); return null;
            });
            PreviewPlaybackObserver observer = new PreviewPlaybackObserver(null,
                    main(() -> (Button) field(activity, "playButton")));
            playAndPausePreview(observer);
            assertEquals("SDK-stop resume does not mutate saved effects, clips, IDs or source pool", preserved, ProjectCodec.encode(project()));
            main(() -> {
                assertTrue("SDK-stop resume prepares the requested graded source position; requested=" + requested
                                + ", firstReady=" + observer.firstReadyPosition,
                        Math.abs(observer.firstReadyPosition - requested) <= 100);
                return null;
            });
            assertColourPreview(); capture("graded-preview-after-sdk-stop");
        }
        void assertErroredPreviewRecovery() throws Exception {
            // Recovery needs an explicit native seek, not a track tap's
            // short-tap vs long-press classification under loaded emulators.
            // The real ruler updates on DOWN; clip selection is tested at
            // 3000ms separately through an actual linked track-block tap.
            tapTimeline(600, true);
            String savedBefore = ProjectCodec.encode(project());
            long requested = main(() -> (Long) field(activity, "playheadMs"));
            CompositionPlayer failed = main(() -> (CompositionPlayer) field(activity, "player"));
            Button pauseButton = main(() -> (Button) field(activity, "playButton"));
            main(() -> {
                // Process-local instrumentation only. Use the pinned SDK's real
                // error transition: it stops the holders and invalidates the
                // SimpleBasePlayer cached state, unlike a private-field write.
                // No bad media, account writes or production injection hook.
                Method fail = CompositionPlayer.class.getDeclaredMethod("maybeUpdatePlaybackError",
                        String.class, Exception.class, int.class);
                fail.setAccessible(true);
                fail.invoke(failed, "Native recovery QA", new IllegalStateException("Native recovery QA"),
                        PlaybackException.ERROR_CODE_TIMEOUT);
                assertNotNull("Pinned native error is exposed through actual cached Player state", failed.getPlayerError());
                assertEquals(PlaybackException.ERROR_CODE_TIMEOUT, failed.getPlayerError().errorCode);
                assertEquals(Player.STATE_IDLE, failed.getPlaybackState());
                return null;
            });
            PreviewPlaybackObserver observer = new PreviewPlaybackObserver(failed, pauseButton);
            playAndPausePreview(observer);
            main(() -> {
                assertTrue("Fresh engine's first READY preserves the requested seek, not zero; requested=" + requested
                                + ", firstReady=" + observer.firstReadyPosition,
                        Math.abs(observer.firstReadyPosition - requested) <= 100);
                assertTrue("Fresh engine actually starts playback at that seek; requested=" + requested
                                + ", firstPlaying=" + observer.firstPlayingPosition,
                        Math.abs(observer.firstPlayingPosition - requested) <= 100);
                long restored = (Long) field(activity, "playheadMs");
                assertTrue("Native Pause retains its immediately observed actual playback position; firstPlaying="
                                + observer.firstPlayingPosition + ", beforePause=" + observer.positionAtPause
                                + ", elapsedMs=" + observer.pauseElapsedMs + ", paused=" + restored,
                        Math.abs(restored - observer.positionAtPause) <= 100);
                return null;
            });
            CompositionPlayer current = main(() -> (CompositionPlayer) field(activity, "player"));
            assertNotSame("An errored CompositionPlayer is replaced, not prepared repeatedly", failed, current);
            assertNull(main(current::getPlayerError));
            assertEquals("Engine recovery does not mutate clips, settings, IDs or the source pool", savedBefore, ProjectCodec.encode(project()));
            waitUntil("Fresh native decoder actually renders the retained red source", 3000, () -> {
                int pixel = monitorCenterPixel();
                return Color.red(pixel) > 170 && Color.green(pixel) < 75 && Color.blue(pixel) < 75;
            });
            capture("preview-recovered");
        }
        int monitorCenterPixel() throws Exception {
            Rect bounds = main(() -> {
                Rect value = new Rect(); assertTrue(((View) field(activity, "playerView")).getGlobalVisibleRect(value)); return value;
            });
            Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot(); assertNotNull(screenshot);
            if (screenshot.getConfig() == Bitmap.Config.HARDWARE) {
                Bitmap readable = screenshot.copy(Bitmap.Config.ARGB_8888, false); screenshot.recycle(); screenshot = readable;
                assertNotNull("Read recovered native monitor pixels", screenshot);
            }
            try { return screenshot.getPixel(bounds.centerX(), bounds.centerY()); }
            finally { screenshot.recycle(); }
        }
        void assertMotionPreview() throws Exception {
            // The source is solid red. Its centered interior is still covered
            // after the tested scale/rotation/offset; 80% opacity must change its
            // actual output RGB, not only the stored control value.
            waitUntil("Latest native motion preview displays actual 80-percent source opacity", 3000, () -> {
                int pixel = monitorCenterPixel();
                return Color.red(pixel) >= 190 && Color.red(pixel) <= 215 && Color.green(pixel) < 15 && Color.blue(pixel) < 15;
            });
        }
        void assertOpacityZeroPreview() throws Exception {
            waitUntil("Paused native redraw applies zero opacity to actual source pixels", 3000, () -> {
                int pixel = monitorCenterPixel();
                return Color.red(pixel) < 15 && Color.green(pixel) < 15 && Color.blue(pixel) < 15;
            });
        }
        void assertColourPreview() throws Exception {
            // Native default SDR RGB matrix composition: source (1,0,0),
            // brightness +.25 -> (1.25,.25,.25), contrast factor .8 ->
            // (1.1,.3,.3), saturation .6 -> (.848032,.368032,.368032),
            // opacity .8 -> (.6784256,.2944256,.2944256): about (173,75,75).
            // Tight screenshot tolerance permits native surface/codec rounding,
            // but rejects stale ungraded red and opacity-only previews.
            final int[] last = new int[1];
            try {
                waitUntil("Latest native colour preview renders the combined saved grade", 3000, () -> {
                    last[0] = monitorCenterPixel();
                    return Math.abs(Color.red(last[0]) - 173) < 18
                            && Math.abs(Color.green(last[0]) - 75) < 18
                            && Math.abs(Color.blue(last[0]) - 75) < 18;
                });
            } catch (AssertionError failure) {
                throw new AssertionError(failure.getMessage() + "; actualRGB=(" + Color.red(last[0]) + ","
                        + Color.green(last[0]) + "," + Color.blue(last[0]) + ")", failure);
            }
        }
        void drainActivityIo() throws Exception {
            ExecutorService io = main(() -> (ExecutorService) field(activity, "io")); io.submit(() -> {}).get(15, TimeUnit.SECONDS);
            instrumentation.waitForIdleSync();
        }
        void tapTimeline(long positionMs, boolean ruler) throws Exception {
            waitPreview();
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
            press.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            long[] dispatched = new long[2];
            try {
                // Real system routing, but do not wait for native surfaces to
                // finish processing DOWN before releasing a short tap. A prior
                // synchronous injection took 1537ms on the loaded emulator and
                // correctly became a long-press/reorder instead of selection.
                assertTrue("System accepts the native touchscreen DOWN", instrumentation.getUiAutomation().injectInputEvent(press, false));
                dispatched[0] = SystemClock.uptimeMillis(); SystemClock.sleep(60);
                MotionEvent release = MotionEvent.obtain(down, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, point[0], point[1], 0);
                release.setSource(InputDevice.SOURCE_TOUCHSCREEN);
                try {
                    assertTrue("System accepts the native touchscreen UP", instrumentation.getUiAutomation().injectInputEvent(release, false));
                    dispatched[1] = SystemClock.uptimeMillis();
                }
                finally { release.recycle(); }
            } finally { press.recycle(); }
            instrumentation.waitForIdleSync();
            try {
                waitUntil("Graphical timeline changes both the stored and actual native-player sequence playhead", 12000,
                        () -> main(() -> {
                            CompositionPlayer player = (CompositionPlayer) field(activity, "player");
                            return Math.abs((Long) field(activity, "playheadMs") - positionMs) < 150
                                    && !(Boolean) field(activity, "previewPending") && player.getPlayerError() == null
                                    && player.getPlaybackState() == Player.STATE_READY
                                    && Math.abs(player.getCurrentPosition() - positionMs) < 150;
                        }));
            } catch (AssertionError failure) {
                String diagnostic = main(() -> {
                    CompositionPlayer player = (CompositionPlayer) field(activity, "player");
                    StudioTimelineView timeline = (StudioTimelineView) field(activity, "timeline");
                    Rect bounds = new Rect(); timeline.getGlobalVisibleRect(bounds); int[] location = new int[2]; timeline.getLocationOnScreen(location);
                    return "request=" + positionMs + "; ruler=" + ruler + "; pointer=(" + point[0] + "," + point[1] + ")"
                            + "; downDispatchMs=" + (dispatched[0] - down) + "; heldMs=" + (dispatched[1] - down)
                            + "; bounds=" + bounds + "; screenOrigin=(" + location[0] + "," + location[1] + ")"
                            + "; windowFocus=" + root().hasWindowFocus() + "; interactive=" + field(timeline, "interactive")
                            + "; dragged=" + field(timeline, "dragged") + "; scrub=" + field(timeline, "scrubbing")
                            + "; scale=" + field(timeline, "pixelsPerSecond") + "; scroll=" + field(timeline, "scroll")
                            + "; selected=" + field(activity, "selected") + "; stored=" + field(activity, "playheadMs")
                            + "; drawn=" + field(timeline, "playhead") + "; pending=" + field(activity, "previewPending")
                            + "; playerState=" + player.getPlaybackState() + "; playerPosition=" + player.getCurrentPosition()
                            + "; error=" + describePlaybackError(player.getPlayerError());
                });
                Log.e("NetVistaNativeUiChecks", "Native timeline input failure: " + diagnostic);
                throw new AssertionError(failure.getMessage() + "; " + diagnostic, failure);
            }
        }
        void edit(String description, String text, boolean done) throws Exception {
            View inspector = panel("inspectorPanel");
            EditText value = main(() -> (EditText) findDescription(inspector, description));
            assertNotNull("Native inspector field: " + description, value); reveal(value);
            main(() -> { assertTrue(value.isEnabled()); value.requestFocus(); value.setText(text);
                if (done) value.onEditorAction(EditorInfo.IME_ACTION_DONE); return null; });
            instrumentation.waitForIdleSync();
        }
        void tapAnimationDiamond(long sourceMs) throws Exception {
            View keys = panel("keyframeTimeline"); assertNotNull(keys); reveal(keys);
            float[] point = main(() -> {
                Rect bounds = new Rect(); assertTrue(keys.getGlobalVisibleRect(bounds));
                StudioProject.Clip clip = ((StudioProject) field(activity, "project")).clips.get((Integer) field(activity, "selected"));
                float density = activity.getResources().getDisplayMetrics().density;
                float x = bounds.left + 14 * density + (keys.getWidth() - 28 * density) * (sourceMs - clip.inMs) / clip.lengthMs();
                return new float[]{x, bounds.top + 48 * density};
            });
            long downTime = SystemClock.uptimeMillis();
            MotionEvent down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, point[0], point[1], 0);
            down.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            try { assertTrue(instrumentation.getUiAutomation().injectInputEvent(down, false)); } finally { down.recycle(); }
            SystemClock.sleep(60);
            MotionEvent up = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, point[0], point[1], 0);
            up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            try { assertTrue(instrumentation.getUiAutomation().injectInputEvent(up, false)); } finally { up.recycle(); }
            waitUntil("Actual animation diamond input seeks the sequence", 12000, () -> main(() -> {
                StudioProject project = (StudioProject) field(activity, "project"); int selected = (Integer) field(activity, "selected");
                long start = 0; for (int index = 0; index < selected; index++) start += project.clips.get(index).lengthMs();
                long expected = start + sourceMs - project.clips.get(selected).inMs;
                CompositionPlayer player = (CompositionPlayer) field(activity, "player");
                return (Long) field(activity, "playheadMs") == expected && player.getPlayerError() == null
                        && Math.abs(player.getCurrentPosition() - expected) < 150;
            }));
        }
        void tapEffectSlider(String description, float fraction) throws Exception {
            View slider = main(() -> findDescription((View) field(activity, "inspectorPanel"), description));
            assertNotNull("Actual native effect slider exists", slider); reveal(slider);
            float[] point = main(() -> { Rect bounds = new Rect(); assertTrue(slider.getGlobalVisibleRect(bounds));
                assertTrue(slider.isEnabled()); return new float[]{bounds.left + bounds.width() * fraction, bounds.exactCenterY()}; });
            long downTime = SystemClock.uptimeMillis();
            MotionEvent down = MotionEvent.obtain(downTime, downTime, MotionEvent.ACTION_DOWN, point[0], point[1], 0);
            down.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            try { assertTrue(instrumentation.getUiAutomation().injectInputEvent(down, false)); } finally { down.recycle(); }
            SystemClock.sleep(80);
            MotionEvent up = MotionEvent.obtain(downTime, SystemClock.uptimeMillis(), MotionEvent.ACTION_UP, point[0], point[1], 0);
            up.setSource(InputDevice.SOURCE_TOUCHSCREEN);
            try { assertTrue(instrumentation.getUiAutomation().injectInputEvent(up, false)); } finally { up.recycle(); }
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
            final int[] pixels = new int[3];
            final String[] activePackage = new String[]{"unknown"};
            try {
                // Native UI idle is not a SurfaceFlinger/GPU presentation
                // barrier after Fit invalidates Canvas. Poll real composited
                // screenshots; never draw the View directly or fake pixels.
                waitUntil("Actual native timeline screenshot displays V1, linked A1 and playhead", 12000, () -> {
                    Rect bounds = main(() -> { Rect value = new Rect(); assertTrue(((View) field(activity, "timeline")).getGlobalVisibleRect(value)); return value; });
                    AccessibilityNodeInfo active = instrumentation.getUiAutomation().getRootInActiveWindow();
                    activePackage[0] = active == null ? "none" : String.valueOf(active.getPackageName());
                    Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot(); assertNotNull(screenshot);
                    if (screenshot.getConfig() == Bitmap.Config.HARDWARE) {
                        Bitmap readable = screenshot.copy(Bitmap.Config.ARGB_8888, false); screenshot.recycle(); screenshot = readable;
                        assertNotNull("Read back native screenshot pixels", screenshot);
                    }
                    try {
                        pixels[0] = 0; pixels[1] = 0; pixels[2] = 0;
                        for (int y = Math.max(0, bounds.top); y < Math.min(screenshot.getHeight(), bounds.bottom); y += 2) {
                            for (int x = Math.max(0, bounds.left); x < Math.min(screenshot.getWidth(), bounds.right); x += 2) {
                                int pixel = screenshot.getPixel(x, y);
                                if (near(pixel, 53, 111, 159)) pixels[0]++;
                                if (near(pixel, 24, 139, 116)) pixels[1]++;
                                if (near(pixel, 240, 91, 94)) pixels[2]++;
                            }
                        }
                        // A system ANR/permission/other-app modal is not a
                        // successful visible NetVista timeline, even if a few
                        // coloured blocks remain visible behind its scrim.
                        return context.getPackageName().equals(activePackage[0])
                                && pixels[0] > 100 && pixels[1] > 100 && pixels[2] > 5;
                    } finally { screenshot.recycle(); }
                });
            } catch (AssertionError failure) {
                throw new AssertionError(failure.getMessage() + "; actualPixels={V1=" + pixels[0] + ", A1="
                        + pixels[1] + ", playhead=" + pixels[2] + "}; activeWindow=" + activePackage[0], failure);
            }
        }
        void assertEmptyMonitor() throws Exception {
            waitUntil("Empty timeline detaches native video and completes its latest preview update", 12000,
                    () -> main(() -> {
                        StudioProject project = (StudioProject) field(activity, "project");
                        androidx.media3.ui.PlayerView view = (androidx.media3.ui.PlayerView) field(activity, "playerView");
                        return project.clips.isEmpty() && !(Boolean) field(activity, "previewPending") && view.getPlayer() == null;
                    }));
            instrumentation.waitForIdleSync();
            Rect bounds = main(() -> {
                Rect value = new Rect(); assertTrue(((View) field(activity, "playerView")).getGlobalVisibleRect(value)); return value;
            });
            Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot(); assertNotNull(screenshot);
            if (screenshot.getConfig() == Bitmap.Config.HARDWARE) {
                Bitmap readable = screenshot.copy(Bitmap.Config.ARGB_8888, false); screenshot.recycle(); screenshot = readable;
                assertNotNull("Read actual empty monitor screenshot pixels", screenshot);
            }
            try {
                for (float portion : new float[]{0.25f, 0.5f, 0.75f}) {
                    int pixel = screenshot.getPixel(bounds.left + Math.round((bounds.width() - 1) * portion), bounds.centerY());
                    assertTrue("Empty timeline clears old source pixels; actual RGB=(" + Color.red(pixel) + ","
                                    + Color.green(pixel) + "," + Color.blue(pixel) + ")",
                            Color.red(pixel) < 20 && Color.green(pixel) < 20 && Color.blue(pixel) < 20);
                }
            } finally { screenshot.recycle(); }
            capture("empty-timeline-monitor");
        }
        private static boolean near(int pixel, int red, int green, int blue) {
            return Math.abs(Color.red(pixel) - red) < 12 && Math.abs(Color.green(pixel) - green) < 12 && Math.abs(Color.blue(pixel) - blue) < 12;
        }
        void capture(String phase) throws Exception {
            instrumentation.waitForIdleSync();
            Bitmap screenshot = instrumentation.getUiAutomation().takeScreenshot(); assertNotNull("Capture actual native device screenshot", screenshot);
            try {
                Configuration configuration = main(() -> new Configuration(activity.getResources().getConfiguration()));
                String name = phase + "_" + configuration.screenWidthDp + "x" + configuration.screenHeightDp + "dp_"
                        + screenshot.getWidth() + "x" + screenshot.getHeight() + ".png";
                QaEvidence.savePng(context, name, screenshot);
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
                waitUntil("Closing short Inspector returns to the actual native editor", 3000,
                        () -> main(() -> root().hasWindowFocus()));
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
