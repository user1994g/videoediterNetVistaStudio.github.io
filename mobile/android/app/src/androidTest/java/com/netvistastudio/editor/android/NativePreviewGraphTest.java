package com.netvistastudio.editor.android;

import android.app.Instrumentation;
import android.net.Uri;
import android.opengl.Matrix;
import androidx.media3.common.Effect;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.GlMatrixTransformation;
import androidx.media3.effect.RgbMatrix;
import androidx.media3.transformer.Composition;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.function.Consumer;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Public native effects contracts, independent of the Activity's redraw routing. */
@UnstableApi
@RunWith(AndroidJUnit4.class)
public final class NativePreviewGraphTest {
    private static final float TOLERANCE = 0.00001f;

    @Test public void liveMatricesMatchNeutralAndCombinedFixedExportEffects() throws Exception {
        try (Fixture fixture = new Fixture()) {
            NativePreviewGraph graph = new NativePreviewGraph(fixture.project.copy(), fixture.files);
            assertArrayEquals(identity(), colour(graph.composition(), 0), 0f);
            assertArrayEquals(exportColour(fixture.project.clips.get(0), fixture.project), colour(graph.composition(), 0), TOLERANCE);
            StudioProject styled = fixture.project.copy(); styled.clips.get(0).settings = styledSettings();
            assertTrue(graph.updateSettings(styled));
            assertArrayEquals(styled.clips.get(0).settings.canvasTransformMatrix(styled.width, styled.height),
                    motion(graph.composition(), 0), 0f);
            assertArrayEquals(exportColour(styled.clips.get(0), styled), colour(graph.composition(), 0), TOLERANCE);
            assertFalse("Initially neutral delegates must remain live", Arrays.equals(identity(), colour(graph.composition(), 0)));
        }
    }

    @Test public void sharedSourcesKeepIndependentLiveInstancesAndAcceptSavedUndoCopy() throws Exception {
        try (Fixture fixture = new Fixture()) {
            NativePreviewGraph graph = new NativePreviewGraph(fixture.project.copy(), fixture.files);
            Composition original = graph.composition();
            float[] untouchedMotion = motion(original, 1), untouchedColour = colour(original, 1);
            StudioProject savedUndo = ProjectCodec.decode(ProjectCodec.encode(fixture.project));
            assertNotSame(fixture.project.clips.get(0), savedUndo.clips.get(0));
            assertEquals(fixture.project.clips.get(0).uri, fixture.project.clips.get(1).uri);
            assertNotEquals(fixture.project.clips.get(0).id, fixture.project.clips.get(1).id);
            StudioProject edited = fixture.project.copy(); edited.clips.get(0).settings = styledSettings();
            assertTrue(graph.updateSettings(edited));
            assertSame("An effect edit retains its exact Composition", original, graph.composition());
            assertArrayEquals(exportColour(edited.clips.get(0), edited), colour(original, 0), TOLERANCE);
            assertArrayEquals(untouchedMotion, motion(original, 1), 0f);
            assertArrayEquals(untouchedColour, colour(original, 1), 0f);
            assertTrue("Undo's saved model copy maps by instance UUID", graph.updateSettings(savedUndo));
            assertSame(original, graph.composition());
            assertArrayEquals(identity(), motion(original, 0), 0f);
            assertArrayEquals(identity(), colour(original, 0), 0f);
            assertArrayEquals(untouchedMotion, motion(original, 1), 0f);
            assertArrayEquals(untouchedColour, colour(original, 1), 0f);
        }
    }

    @Test public void structuralChangesAreRejectedBeforeAnySettingsArePublished() throws Exception {
        try (Fixture fixture = new Fixture()) {
            NativePreviewGraph graph = new NativePreviewGraph(fixture.project.copy(), fixture.files);
            Composition original = graph.composition();
            float[][] initialMotion = {motion(original, 0), motion(original, 1)};
            float[][] initialColour = {colour(original, 0), colour(original, 1)};
            List<Consumer<StudioProject>> changes = Arrays.asList(
                    project -> java.util.Collections.swap(project.clips, 0, 1),
                    project -> replaceSecond(project, UUID.randomUUID().toString(), null, 0, 0, 0),
                    project -> replaceSecond(project, null, "media/" + UUID.randomUUID() + ".video", 0, 0, 0),
                    project -> replaceSecond(project, null, null, 1, 0, 0),
                    project -> replaceSecond(project, null, null, 0, 1, 0),
                    project -> replaceSecond(project, null, null, 0, 0, -1),
                    project -> project.width += 2,
                    project -> project.height += 2);
            for (int index = 0; index < changes.size(); index++) {
                StudioProject changed = fixture.project.copy();
                // A valid early-instance edit must not leak through when a later
                // instance (or the canvas) invalidates the structural snapshot.
                changed.clips.get(0).settings = styledSettings(); changes.get(index).accept(changed);
                assertFalse("Structural mutation " + index + " requires a new graph", graph.updateSettings(changed));
                assertSame(original, graph.composition());
                for (int clip = 0; clip < 2; clip++) {
                    assertArrayEquals(initialMotion[clip], motion(original, clip), 0f);
                    assertArrayEquals(initialColour[clip], colour(original, clip), 0f);
                }
            }
        }
    }

    private static StudioProject.ClipSettings styledSettings() {
        return new StudioProject.ClipSettings(1.25f, 15f, 0.2f, 0.15f, 0.8f,
                0.25f, GradeControlValues.nativeContrast(80f), 0.6f);
    }

    private static void replaceSecond(StudioProject project, String id, String uri, long durationDelta,
                                      long inDelta, long outDelta) {
        StudioProject.Clip clip = project.clips.get(1);
        project.clips.set(1, new StudioProject.Clip(id == null ? clip.id : id, uri == null ? clip.uri : uri,
                clip.name, clip.durationMs + durationDelta, clip.inMs + inDelta, clip.outMs + outDelta,
                clip.settings.copy()));
    }

    private static List<Effect> effects(Composition composition, int clip) {
        return composition.sequences.get(0).editedMediaItems.get(clip).effects.videoEffects;
    }

    private static float[] motion(Composition composition, int clip) {
        List<Effect> effects = effects(composition, clip);
        assertEquals("Presentation and both live delegates always exist", 3, effects.size());
        assertTrue(effects.get(1) instanceof GlMatrixTransformation);
        return ((GlMatrixTransformation) effects.get(1)).getGlMatrixArray(0).clone();
    }

    private static float[] colour(Composition composition, int clip) {
        List<Effect> effects = effects(composition, clip);
        assertEquals(3, effects.size()); assertTrue(effects.get(2) instanceof RgbMatrix);
        return ((RgbMatrix) effects.get(2)).getMatrix(0, false).clone();
    }

    private static float[] exportColour(StudioProject.Clip clip, StudioProject project) {
        float[] combined = identity();
        for (Effect effect : MobileExport.videoEffects(clip, project.width, project.height)) {
            if (!(effect instanceof RgbMatrix)) continue;
            float[] result = new float[16];
            // Android's independent matrix implementation is the SDK shader's oracle.
            Matrix.multiplyMM(result, 0, ((RgbMatrix) effect).getMatrix(0, false), 0, combined, 0);
            combined = result;
        }
        return combined;
    }

    private static float[] identity() {
        float[] value = new float[16]; Matrix.setIdentityM(value, 0); return value;
    }

    private static final class Fixture implements AutoCloseable {
        final ProjectFiles files;
        final StudioProject project = new StudioProject();
        final File scratch, fixture;
        File imported;

        Fixture() throws Exception {
            Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
            files = new ProjectFiles(instrumentation.getTargetContext());
            scratch = new File(instrumentation.getTargetContext().getCacheDir(), "preview-graph-" + UUID.randomUUID());
            assertTrue(scratch.mkdir()); fixture = new File(scratch, "red-source.mp4");
            try {
                try (InputStream input = instrumentation.getContext().getAssets().open("export-fixtures/red-silent-landscape.mp4");
                     FileOutputStream output = new FileOutputStream(fixture)) {
                    ProjectFiles.copy(input, output, 1024 * 1024);
                }
                String sourceId = UUID.randomUUID().toString(); imported = files.importVideo(Uri.fromFile(fixture), sourceId);
                String uri = "media/" + sourceId + ".video";
                project.width = 1280; project.height = 720;
                project.assets.add(new StudioProject.Clip(sourceId, uri, "Shared red source", 3000, 0, 3000));
                project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), uri, "First instance", 3000, 100, 2400));
                project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), uri, "Second instance", 3000, 300, 2500));
            } catch (Exception | AssertionError failure) { close(); throw failure; }
        }

        @Override public void close() {
            if (imported != null) imported.delete();
            fixture.delete(); scratch.delete();
        }
    }
}
