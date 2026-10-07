package com.netvistastudio.editor.android;

import android.app.Instrumentation;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.media.AudioFormat;
import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMetadataRetriever;
import android.net.Uri;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import androidx.media3.common.MediaItem;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.transformer.Composition;
import androidx.media3.transformer.ExportException;
import androidx.media3.transformer.ExportResult;
import androidx.media3.transformer.Transformer;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Real device codecs/rendering, synthetic local media, no Activity or account service. */
@UnstableApi
@RunWith(AndroidJUnit4.class)
public final class MobileExportIntegrationTest {
    @Test(timeout = 180000)
    public void importedPortableProjectRendersTrimmedMixedAspectVideoAndAudio() throws Exception {
        assertFalse("Never wait for export on its application looper", Looper.myLooper() == Looper.getMainLooper());
        Instrumentation instrumentation = InstrumentationRegistry.getInstrumentation();
        Context context = instrumentation.getTargetContext();
        ProjectFiles files = new ProjectFiles(context);
        File scratch = new File(context.getCacheDir(), "export-integration-" + UUID.randomUUID());
        assertTrue("Create a private disposable test directory", scratch.mkdir());
        List<File> ownedMedia = new ArrayList<>();
        AtomicReference<Transformer> active = new AtomicReference<>();
        try {
            File redFixture = copyFixture(instrumentation, scratch, "red-silent-landscape.mp4");
            File blueFixture = copyFixture(instrumentation, scratch, "blue-audio-portrait.mp4");
            assertEquals("Silent source has no audio track", 0, countTracks(redFixture, "audio/"));
            assertEquals("Second source has real AAC", 1, countTracks(blueFixture, "audio/"));
            assertEquals("Both fixtures contain video", 1, countTracks(redFixture, "video/"));
            assertEquals(1, countTracks(blueFixture, "video/"));

            String redID = UUID.randomUUID().toString(), blueID = UUID.randomUUID().toString();
            File red = files.importVideo(Uri.fromFile(redFixture), redID);
            ownedMedia.add(red);
            File blue = files.importVideo(Uri.fromFile(blueFixture), blueID);
            ownedMedia.add(blue);
            assertEquals("Import copies source bytes into app-private media", redFixture.length(), red.length());
            assertEquals(blueFixture.length(), blue.length());
            long redDuration = durationMs(red), blueDuration = durationMs(blue);
            assertTrue(Math.abs(redDuration - 3000) <= 50);
            assertTrue(Math.abs(blueDuration - 3000) <= 50);

            StudioProject project = new StudioProject();
            project.title = "Synthetic archive/export integration";
            project.width = 1280; project.height = 720;
            // Start reversed, then reorder. Red becomes 1.2s, followed by 1.6s blue.
            project.clips.add(new StudioProject.Clip(blueID, "media/" + blueID + ".video", "Blue portrait with tone", blueDuration, 400, 2000));
            project.clips.add(new StudioProject.Clip(redID, "media/" + redID + ".video", "Silent red landscape", redDuration, 300, 1500));
            project.move(1, 0);
            assertEquals(2800, project.durationMs());

            File archive = new File(scratch, "Synthetic.netvistamobile");
            try (FileOutputStream output = new FileOutputStream(archive)) { files.saveArchive(project, output); }
            assertTrue("Saved project contains its media", archive.length() > red.length() + blue.length());
            assertTrue(red.delete()); assertTrue(blue.delete());
            StudioProject restored;
            try (InputStream input = new FileInputStream(archive)) { restored = files.loadArchive(input); }
            for (StudioProject.Clip clip : restored.clips) ownedMedia.add(files.mediaFile(clip));
            assertEquals("Reopen survives removal of both original imports", 2, restored.clips.size());
            assertEquals(project.title, restored.title);
            assertEquals(2800, restored.durationMs());
            assertEquals("Silent red landscape", restored.clips.get(0).name);
            assertNotEquals(redID, restored.clips.get(0).id);
            assertNotEquals(blueID, restored.clips.get(1).id);

            List<MediaItem> preview = MobileExport.previewItems(restored, files);
            assertEquals(300, preview.get(0).clippingConfiguration.startPositionMs);
            assertEquals(1500, preview.get(0).clippingConfiguration.endPositionMs);
            assertEquals(400, preview.get(1).clippingConfiguration.startPositionMs);
            assertEquals(2000, preview.get(1).clippingConfiguration.endPositionMs);
            Composition composition = MobileExport.composition(restored, files);
            File movie = new File(scratch, "actual-export.mp4");
            assertFalse("Transformer creates its own output file", movie.exists());
            CountDownLatch finished = new CountDownLatch(1);
            AtomicReference<Throwable> failure = new AtomicReference<>();
            AtomicReference<ExportResult> result = new AtomicReference<>();
            instrumentation.runOnMainSync(() -> {
                try {
                    Transformer transformer = MobileExport.transformer(context, new Transformer.Listener() {
                        @Override public void onCompleted(Composition value, ExportResult exported) {
                            result.set(exported); active.set(null); finished.countDown();
                        }
                        @Override public void onError(Composition value, ExportResult exported, ExportException error) {
                            failure.set(error); active.set(null); finished.countDown();
                        }
                    });
                    active.set(transformer);
                    transformer.start(composition, movie.getAbsolutePath());
                } catch (Throwable error) { failure.set(error); finished.countDown(); }
            });
            assertTrue("Native Media3 export must complete within 120 seconds", finished.await(120, TimeUnit.SECONDS));
            if (failure.get() != null) throw new AssertionError("Native composition/export failed", failure.get());
            assertNotNull("Successful Transformer completion callback", result.get());
            assertTrue("A nonempty movie was actually encoded", movie.isFile() && movie.length() > 2000);
            assertTrue("Trims determine the encoded duration, not full source lengths", Math.abs(durationMs(movie) - 2800) <= 180);
            assertExportTracks(movie);
            assertRenderedColorsAndPortraitFit(movie);
            assertAudibleSecondClipAndSilentFirstClip(movie);
            Log.i("NetVistaExportChecks", "PASS: app-private import, self-contained save/reopen, order/trim, mixed aspect, missing source audio, visible 720p H264 frames and audible AAC export");
        } finally {
            instrumentation.runOnMainSync(() -> {
                Transformer transformer = active.getAndSet(null);
                if (transformer != null) transformer.cancel();
            });
            // Only UUID-created test imports and this test's scratch files are removed.
            for (File file : ownedMedia) file.delete();
            File[] temporary = scratch.listFiles();
            if (temporary != null) for (File file : temporary) file.delete();
            scratch.delete();
        }
    }

    private static File copyFixture(Instrumentation instrumentation, File directory, String name) throws Exception {
        File destination = new File(directory, name);
        try (InputStream input = instrumentation.getContext().getAssets().open("export-fixtures/" + name);
             FileOutputStream output = new FileOutputStream(destination)) {
            ProjectFiles.copy(input, output, 1024 * 1024);
        }
        return destination;
    }

    private static long durationMs(File file) throws Exception {
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            retriever.setDataSource(file.getAbsolutePath());
            String duration = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION);
            assertNotNull("Encoded media has a duration", duration);
            return Long.parseLong(duration);
        } finally { retriever.release(); }
    }

    private static int countTracks(File file, String prefix) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(file.getAbsolutePath());
            int count = 0;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                String mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith(prefix)) count++;
            }
            return count;
        } finally { extractor.release(); }
    }

    private static void assertExportTracks(File file) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(file.getAbsolutePath());
            int videos = 0, audio = 0;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat format = extractor.getTrackFormat(i);
                String mime = format.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("video/")) {
                    videos++; assertEquals("video/avc", mime);
                    assertEquals("Selected 720p width is encoded", 1280, format.getInteger(MediaFormat.KEY_WIDTH));
                    assertEquals("Selected 720p height is encoded", 720, format.getInteger(MediaFormat.KEY_HEIGHT));
                } else if (mime != null && mime.startsWith("audio/")) {
                    audio++; assertEquals("audio/mp4a-latm", mime);
                }
            }
            assertEquals("One real H264 output track", 1, videos);
            assertEquals("Mixed silent/audible sources produce one AAC track", 1, audio);
        } finally { extractor.release(); }
    }

    private static void assertRenderedColorsAndPortraitFit(File movie) throws Exception {
        MediaMetadataRetriever retriever = new MediaMetadataRetriever();
        try {
            retriever.setDataSource(movie.getAbsolutePath());
            assertColor(retriever, 500000, true);
            assertColor(retriever, 1050000, true);
            assertColor(retriever, 1450000, false);
            Bitmap portrait = retriever.getFrameAtTime(2200000, MediaMetadataRetriever.OPTION_CLOSEST);
            assertNotNull("Decode an actual second-clip output frame", portrait);
            try {
                assertBlue(portrait.getPixel(portrait.getWidth() / 2, portrait.getHeight() / 2));
                int edge = portrait.getPixel(portrait.getWidth() / 20, portrait.getHeight() / 2);
                assertTrue("Portrait footage is fit with black side bars, not stretched/cropped", Color.red(edge) < 40 && Color.green(edge) < 40 && Color.blue(edge) < 40);
            } finally { portrait.recycle(); }
        } finally { retriever.release(); }
    }

    private static void assertColor(MediaMetadataRetriever retriever, long timeUs, boolean red) {
        Bitmap frame = retriever.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST);
        assertNotNull("Decode a nonblack frame at " + timeUs, frame);
        try {
            int pixel = frame.getPixel(frame.getWidth() / 2, frame.getHeight() / 2);
            if (red) assertTrue("Red clip remains visible before its trimmed sequence boundary", Color.red(pixel) > 180 && Color.green(pixel) < 70 && Color.blue(pixel) < 70);
            else assertBlue(pixel);
        } finally { frame.recycle(); }
    }

    private static void assertBlue(int pixel) {
        assertTrue("Blue clip becomes visible after the trimmed sequence boundary", Color.blue(pixel) > 180 && Color.red(pixel) < 70 && Color.green(pixel) < 70);
    }

    private static void assertAudibleSecondClipAndSilentFirstClip(File movie) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec decoder = null; boolean started = false;
        try {
            extractor.setDataSource(movie.getAbsolutePath());
            MediaFormat source = null;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat format = extractor.getTrackFormat(i);
                String mime = format.getString(MediaFormat.KEY_MIME);
                if (mime != null && mime.startsWith("audio/")) { source = format; extractor.selectTrack(i); break; }
            }
            assertNotNull("Decode real output audio rather than accepting an empty track", source);
            decoder = MediaCodec.createDecoderByType(source.getString(MediaFormat.KEY_MIME));
            decoder.configure(source, null, null, 0); decoder.start(); started = true;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            boolean inputEnded = false, outputEnded = false;
            int channels = source.getInteger(MediaFormat.KEY_CHANNEL_COUNT);
            int rate = source.getInteger(MediaFormat.KEY_SAMPLE_RATE), encoding = AudioFormat.ENCODING_PCM_16BIT;
            double silentSquares = 0, audibleSquares = 0;
            long silentCount = 0, audibleCount = 0;
            long deadline = SystemClock.elapsedRealtime() + 30000;
            while (!outputEnded && SystemClock.elapsedRealtime() < deadline) {
                if (!inputEnded) {
                    int inputIndex = decoder.dequeueInputBuffer(10000);
                    if (inputIndex >= 0) {
                        ByteBuffer buffer = decoder.getInputBuffer(inputIndex);
                        assertNotNull(buffer); buffer.clear();
                        int count = extractor.readSampleData(buffer, 0);
                        if (count < 0) {
                            decoder.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inputEnded = true;
                        } else {
                            decoder.queueInputBuffer(inputIndex, 0, count, extractor.getSampleTime(), 0); extractor.advance();
                        }
                    }
                }
                int index = decoder.dequeueOutputBuffer(info, 10000);
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat format = decoder.getOutputFormat();
                    channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT); rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE);
                    if (format.containsKey(MediaFormat.KEY_PCM_ENCODING)) encoding = format.getInteger(MediaFormat.KEY_PCM_ENCODING);
                    assertTrue("Supported signed/float PCM decoder output", encoding == AudioFormat.ENCODING_PCM_16BIT || encoding == AudioFormat.ENCODING_PCM_FLOAT);
                } else if (index >= 0) {
                    ByteBuffer buffer = decoder.getOutputBuffer(index);
                    if (info.size > 0) {
                        assertNotNull(buffer); buffer.position(info.offset); buffer.limit(info.offset + info.size); buffer.order(ByteOrder.nativeOrder());
                        int bytesPerSample = encoding == AudioFormat.ENCODING_PCM_FLOAT ? 4 : 2;
                        int sampleIndex = 0;
                        while (buffer.remaining() >= bytesPerSample) {
                            double sample = encoding == AudioFormat.ENCODING_PCM_FLOAT ? buffer.getFloat() : buffer.getShort() / 32768.0;
                            double seconds = info.presentationTimeUs / 1000000.0 + (sampleIndex / channels) / (double) rate;
                            sampleIndex++;
                            assertTrue("Finite decoded audio", Double.isFinite(sample));
                            if (seconds >= 0.2 && seconds <= 0.9) { silentSquares += sample * sample; silentCount++; }
                            if (seconds >= 1.45 && seconds <= 2.6) { audibleSquares += sample * sample; audibleCount++; }
                        }
                    }
                    outputEnded = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                    decoder.releaseOutputBuffer(index, false);
                }
            }
            assertTrue("Audio decoder completes within 30 seconds", outputEnded);
            assertTrue("Silence fills the first clip instead of shifting the later audio", silentCount > 1000);
            assertTrue("Second clip contributes decoded audio samples", audibleCount > 1000);
            double silentRms = Math.sqrt(silentSquares / silentCount), audibleRms = Math.sqrt(audibleSquares / audibleCount);
            assertTrue("First source remains silent: " + silentRms, silentRms < 0.005);
            assertTrue("Second source's 440Hz tone is audible, not an empty AAC track: " + audibleRms, audibleRms > 0.01);
            Log.i("NetVistaExportChecks", "Decoded audio RMS: first=" + silentRms + " second=" + audibleRms);
        } finally {
            if (decoder != null) { try { if (started) decoder.stop(); } finally { decoder.release(); } }
            extractor.release();
        }
    }
}
