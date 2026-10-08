package com.netvistastudio.editor.android;

import android.app.Instrumentation;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Looper;
import android.util.Log;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.transformer.Composition;
import androidx.media3.transformer.EditedMediaItem;
import androidx.media3.transformer.ExportException;
import androidx.media3.transformer.ExportResult;
import androidx.media3.transformer.Transformer;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Native encoder and decoded pixel evidence; does not use UI callbacks as an effect oracle. */
@UnstableApi
@RunWith(AndroidJUnit4.class)
public final class ClipEffectsIntegrationTest {
    private static final long EDIT_LENGTH_MS = 600;
    private static final String ID = "fe813cc1-e815-4da4-a520-613366184629";

    @Test public void schemaTwoRetainsEffectsAndSharedSourcesAndReadsSchemaOneDefaults() throws Exception {
        StudioProject project = new StudioProject();
        StudioProject.Clip clip = new StudioProject.Clip(ID, "media/" + ID + ".video", "Source", 10000, 1200, 8000,
                new StudioProject.ClipSettings(1.5f, 20f, 0.25f, -0.5f, 0.8f, 0.1f, -0.2f, 1.2f));
        project.assets.add(clip.fullSource()); project.clips.add(clip); project.split(0, 3500);
        String encoded = ProjectCodec.encode(project);
        assertEquals(2, new JSONObject(encoded).getInt("version"));
        StudioProject reopened = ProjectCodec.decode(encoded);
        assertEquals(2, reopened.clips.size()); assertEquals(1, reopened.assets.size());
        assertNotEquals(reopened.clips.get(0).id, reopened.clips.get(1).id);
        assertEquals(reopened.clips.get(0).uri, reopened.clips.get(1).uri);
        StudioProject.ClipSettings settings = reopened.clips.get(1).settings;
        assertEquals(1.5f, settings.scale, 0f); assertEquals(20f, settings.rotationDegrees, 0f);
        assertEquals(0.25f, settings.positionX, 0f); assertEquals(-0.5f, settings.positionY, 0f);
        assertEquals(0.8f, settings.opacity, 0f); assertEquals(0.1f, settings.brightness, 0f);
        assertEquals(-0.2f, settings.contrast, 0f); assertEquals(1.2f, settings.saturation, 0f);
        assertEquals(0, reopened.assets.get(0).inMs); assertEquals(10000, reopened.assets.get(0).outMs);
        assertEquals(1f, reopened.assets.get(0).settings.scale, 0f);
        reopened.clips.clear();
        assertEquals("Media pool survives removal of all timeline instances", 1,
                ProjectCodec.decode(ProjectCodec.encode(reopened)).assets.size());

        JSONObject legacy = new JSONObject(encoded); legacy.put("version", 1); legacy.remove("assets");
        // An actual old file has one ID==source clip with no effects or pool.
        JSONObject legacyClip = legacy.getJSONArray("clips").getJSONObject(0);
        legacyClip.remove("settings"); legacy.put("clips", new JSONArray().put(legacyClip));
        StudioProject old = ProjectCodec.decode(legacy.toString());
        assertEquals(1f, old.clips.get(0).settings.scale, 0f);
        assertEquals(1f, old.clips.get(0).settings.opacity, 0f);
        assertEquals(1f, old.clips.get(0).settings.saturation, 0f);
        assertEquals(1, old.assets.size()); assertEquals(0, old.assets.get(0).inMs);
        assertEquals(10000, old.assets.get(0).outMs);

        JSONObject invalid = new JSONObject(encoded);
        invalid.getJSONArray("clips").getJSONObject(0).getJSONObject("settings").put("opacity", 2);
        try { ProjectCodec.decode(invalid.toString()); fail("Accepted invalid saved opacity"); }
        catch (org.json.JSONException expected) { /* expected */ }
    }

    @Test(timeout = 180000)
    public void perClipEffectsActuallyChangeDecodedExportPixelsOnFixedCanvas() throws Exception {
        assertFalse("Do not block Transformer application looper", Looper.myLooper() == Looper.getMainLooper());
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        Context context = instrumentation.getTargetContext();
        ProjectFiles files = new ProjectFiles(context);
        File scratch = new File(context.getCacheDir(), "clip-effects-" + UUID.randomUUID());
        assertTrue(scratch.mkdir());
        AtomicReference<Transformer> active = new AtomicReference<>();
        File source = null;
        try {
            File fixture = new File(scratch, "red-source.mp4");
            try (InputStream input = instrumentation.getContext().getAssets().open("export-fixtures/red-silent-landscape.mp4");
                 FileOutputStream output = new FileOutputStream(fixture)) {
                ProjectFiles.copy(input, output, 1024 * 1024);
            }
            String sourceId = UUID.randomUUID().toString();
            source = files.importVideo(Uri.fromFile(fixture), sourceId);
            long sourceDuration = duration(source);
            StudioProject project = new StudioProject(); project.width = 1280; project.height = 720;
            StudioProject.ClipSettings[] variants = {
                    new StudioProject.ClipSettings(), // 0: baseline
                    new StudioProject.ClipSettings(1f, 0f, 0f, 0f, 1f, 0.25f, 0f, 1f), // 1: brighter
                    new StudioProject.ClipSettings(1f, 0f, 0f, 0f, 1f, 0f, -0.6f, 1f), // 2: low contrast
                    new StudioProject.ClipSettings(1f, 0f, 0f, 0f, 1f, 0f, 0f, 0f), // 3: grayscale
                    new StudioProject.ClipSettings(1f, 0f, 0f, 0f, 0f, 0f, 0f, 1f), // 4: transparent to black
                    new StudioProject.ClipSettings(0.5f, 0f, 0f, 0f, 1f, 0f, 0f, 1f), // 5: half scale
                    new StudioProject.ClipSettings(1f, 0f, 1f, 0f, 1f, 0f, 0f, 1f), // 6: half canvas right
                    new StudioProject.ClipSettings(1f, 0f, 0f, 1f, 1f, 0f, 0f, 1f), // 7: half canvas up
                    new StudioProject.ClipSettings(1f, 90f, 0f, 0f, 1f, 0f, 0f, 1f) // 8: 90 degree pixel rotation
            };
            for (int index = 0; index < variants.length; index++) {
                project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), "media/" + sourceId + ".video",
                        "Effect " + index, sourceDuration, 0, EDIT_LENGTH_MS, variants[index]));
            }
            assertEquals("Nine independent edit IDs share one physical source", 1, project.sources().size());
            Composition composition = MobileExport.composition(project, files);
            for (EditedMediaItem item : composition.sequences.get(0).editedMediaItems) {
                assertEquals("CompositionPlayer requires full source duration before clip trim", sourceDuration * 1000, item.durationUs);
                assertEquals(EDIT_LENGTH_MS, item.mediaItem.clippingConfiguration.endPositionMs
                        - item.mediaItem.clippingConfiguration.startPositionMs);
            }
            File movie = new File(scratch, "effects-output.mp4");
            CountDownLatch completed = new CountDownLatch(1);
            AtomicReference<Throwable> error = new AtomicReference<>();
            instrumentation.runOnMainSync(() -> {
                try {
                    Transformer transformer = MobileExport.transformer(context, new Transformer.Listener() {
                        @Override public void onCompleted(Composition value, ExportResult result) {
                            active.set(null); completed.countDown();
                        }
                        @Override public void onError(Composition value, ExportResult result, ExportException failure) {
                            error.set(failure); active.set(null); completed.countDown();
                        }
                    });
                    active.set(transformer); transformer.start(composition, movie.getAbsolutePath());
                } catch (Throwable failure) { error.set(failure); completed.countDown(); }
            });
            assertTrue("Actual edited movie must encode within 120 seconds", completed.await(120, TimeUnit.SECONDS));
            if (error.get() != null) throw new AssertionError("Real clip effect export failed", error.get());
            assertTrue(movie.isFile() && movie.length() > 2000);
            assertTrue(Math.abs(duration(movie) - EDIT_LENGTH_MS * variants.length) <= 180);

            MediaMetadataRetriever retriever = new MediaMetadataRetriever();
            try {
                retriever.setDataSource(movie.getAbsolutePath());
                retainDecodedEvidence(context, retriever, variants.length);
                int baseline = pixel(retriever, 0, 0.5f, 0.5f);
                assertRed("Baseline red fixture is actually visible", baseline);
                assertRed("Baseline source fills the chosen aspect-fit canvas", pixel(retriever, 0, 0.1f, 0.5f));
                int brighter = pixel(retriever, 1, 0.5f, 0.5f);
                assertTrue("Brightness affects decoded RGB, not just a stored slider",
                        Color.green(brighter) > Color.green(baseline) + 60 && Color.blue(brighter) > Color.blue(baseline) + 60);
                int lowContrast = pixel(retriever, 2, 0.5f, 0.5f);
                assertTrue("Lower contrast raises dark channels and reduces decoded channel separation",
                        Color.green(lowContrast) > Color.green(baseline) + 60 && spread(lowContrast) < spread(baseline) - 60);
                int gray = pixel(retriever, 3, 0.5f, 0.5f);
                // The tested Media3 1.11.1 default SDR pipeline produces this matrix
                // result in encoded BT.709 RGB, despite the generic RgbMatrix docs'
                // linear-working-space description. Device evidence was baseline
                // (253,0,0) -> (54,54,54): 253 * 0.2126 = 53.79. Derive the expected
                // luma from the actual decoded input, not an arbitrary brightness
                // threshold which incorrectly rejects a valid dark gray. Do not
                // claim linear-light/Mac colour parity until explicitly configured
                // and verified in both CompositionPlayer and Transformer.
                float expectedGray = 0.2126f * Color.red(baseline)
                        + 0.7152f * Color.green(baseline) + 0.0722f * Color.blue(baseline);
                String grayEvidence = "Decoded saturation zero; actual=" + rgb(gray)
                        + "; baseline=" + rgb(baseline) + "; expected encoded BT.709 luma=" + expectedGray;
                assertTrue(grayEvidence + "; grayscale channels agree", spread(gray) < 8);
                assertEquals(grayEvidence + "; red channel", expectedGray, Color.red(gray), 8f);
                assertEquals(grayEvidence + "; green channel", expectedGray, Color.green(gray), 8f);
                assertEquals(grayEvidence + "; blue channel", expectedGray, Color.blue(gray), 8f);
                assertBlack("Opacity zero must show background in opaque H264", pixel(retriever, 4, 0.5f, 0.5f));
                assertRed("Half scale keeps the source center", pixel(retriever, 5, 0.5f, 0.5f));
                assertBlack("Half scale reveals canvas at the edge instead of changing export dimensions", pixel(retriever, 5, 0.1f, 0.5f));
                assertBlack("X=1 moves the source one half-canvas right", pixel(retriever, 6, 0.25f, 0.5f));
                assertRed("Translated source stays visible on the right", pixel(retriever, 6, 0.75f, 0.5f));
                assertRed("Positive Y is UP, matching native coordinate contract", pixel(retriever, 7, 0.5f, 0.25f));
                assertBlack("Upward translated source reveals background below", pixel(retriever, 7, 0.5f, 0.75f));
                assertRed("Rotated source stays centered", pixel(retriever, 8, 0.5f, 0.5f));
                assertBlack("90 degree rotation respects pixel aspect and leaves black sides", pixel(retriever, 8, 0.1f, 0.5f));
            } finally { retriever.release(); }
        } finally {
            instrumentation.runOnMainSync(() -> {
                Transformer transformer = active.getAndSet(null);
                if (transformer != null) transformer.cancel();
            });
            if (source != null) source.delete();
            File[] temporary = scratch.listFiles();
            if (temporary != null) for (File file : temporary) file.delete();
            scratch.delete();
        }
    }

    private static int pixel(MediaMetadataRetriever retriever, int index, float x, float y) {
        long positionUs = (index * EDIT_LENGTH_MS + EDIT_LENGTH_MS / 2) * 1000;
        Bitmap frame = retriever.getFrameAtTime(positionUs, MediaMetadataRetriever.OPTION_CLOSEST);
        assertNotNull("Decode actual frame for clip " + index, frame);
        try {
            assertEquals("Export canvas width remains fixed", 1280, frame.getWidth());
            assertEquals("Export canvas height remains fixed", 720, frame.getHeight());
            return frame.getPixel(Math.round((frame.getWidth() - 1) * x), Math.round((frame.getHeight() - 1) * y));
        } finally { frame.recycle(); }
    }

    private static void retainDecodedEvidence(Context context, MediaMetadataRetriever retriever, int count) throws Exception {
        File external = context.getExternalFilesDir(null); assertNotNull(external);
        File directory = new File(external, "ui-screenshots");
        assertTrue(directory.isDirectory() || directory.mkdirs());
        StringBuilder values = new StringBuilder("Decoded centres from actual H.264 exports (R,G,B)\n");
        for (int index = 0; index < count; index++) {
            long positionUs = (index * EDIT_LENGTH_MS + EDIT_LENGTH_MS / 2) * 1000;
            Bitmap frame = retriever.getFrameAtTime(positionUs, MediaMetadataRetriever.OPTION_CLOSEST);
            assertNotNull("Decode retained effect evidence " + index, frame);
            try {
                String value = "Effect " + index + ": " + rgb(frame.getPixel(frame.getWidth() / 2, frame.getHeight() / 2));
                values.append(value).append('\n'); Log.i("NetVistaNativeEffectChecks", value);
                QaEvidence.savePng(context, "effect-export-" + index + ".png", frame);
            } finally { frame.recycle(); }
        }
        try (FileOutputStream output = new FileOutputStream(new File(directory, "effect-export-rgb.txt"))) {
            output.write(values.toString().getBytes(StandardCharsets.UTF_8));
        }
    }

    private static String rgb(int pixel) {
        return "(" + Color.red(pixel) + "," + Color.green(pixel) + "," + Color.blue(pixel) + ")";
    }

    private static int spread(int pixel) {
        int max = Math.max(Color.red(pixel), Math.max(Color.green(pixel), Color.blue(pixel)));
        int min = Math.min(Color.red(pixel), Math.min(Color.green(pixel), Color.blue(pixel)));
        return max - min;
    }

    private static void assertRed(String message, int pixel) {
        assertTrue(message, Color.red(pixel) > 170 && Color.green(pixel) < 75 && Color.blue(pixel) < 75);
    }

    private static void assertBlack(String message, int pixel) {
        assertTrue(message, Color.red(pixel) < 40 && Color.green(pixel) < 40 && Color.blue(pixel) < 40);
    }

    private static long duration(File file) throws Exception {
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            retriever.setDataSource(file.getAbsolutePath());
            String value = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            assertNotNull(value); return Long.parseLong(value);
        } finally { retriever.release(); }
    }
}
