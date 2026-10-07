package com.netvistastudio.editor.android;

import android.content.Context;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.media3.common.C;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.transformer.Composition;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

@UnstableApi
@RunWith(AndroidJUnit4.class)
public final class ProjectFilesTest {
    private static final String ID = "809bfe59-a0c0-4db8-9b5d-bd713a47d406";
    @Test public void projectArchiveEmbedsMediaAndLoadsIndependentCopy() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext(); ProjectFiles files = new ProjectFiles(context);
        StudioProject project = new StudioProject();
        StudioProject.Clip clip = new StudioProject.Clip(ID, "media/" + ID + ".video", "fixture", 10000, 1200, 8000);
        project.clips.add(clip); byte[] original = "fixture source bytes".getBytes(StandardCharsets.UTF_8);
        try (FileOutputStream out = new FileOutputStream(files.mediaFile(clip))) { out.write(original); }
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); files.saveArchive(project, bytes);
        StudioProject loaded = files.loadArchive(new ByteArrayInputStream(bytes.toByteArray()));
        assertEquals(6800, loaded.durationMs()); assertNotEquals(ID, loaded.clips.get(0).id);
        assertEquals(original.length, files.mediaFile(loaded.clips.get(0)).length());
        assertArrayEquals(original, java.nio.file.Files.readAllBytes(files.mediaFile(loaded.clips.get(0)).toPath()));
        files.mediaFile(clip).delete(); files.mediaFile(loaded.clips.get(0)).delete();
    }
    @Test public void archiveRejectsTraversalAndDoesNotCreateOutsideFile() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        String outsideName = "unsafe-" + java.util.UUID.randomUUID() + ".mp4";
        java.io.File outside = new java.io.File(context.getCacheDir(), outsideName);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(bytes)) { zip.putNextEntry(new ZipEntry("../" + outsideName)); zip.write(new byte[]{1, 2, 3}); zip.closeEntry(); }
        ProjectFiles files = new ProjectFiles(context);
        try { files.loadArchive(new ByteArrayInputStream(bytes.toByteArray())); fail("Accepted traversal"); }
        catch (java.io.IOException expected) {
            // Android 14+ can reject the ZIP path before our own validator runs.
            // Assert the safety contract, not an OS-specific exception message.
            assertFalse("Traversal must never write outside staging", outside.exists());
        }
    }
    @Test public void malformedProjectTrimIsRejected() throws Exception {
        StudioProject value = new StudioProject(); value.clips.add(new StudioProject.Clip(ID, "media/" + ID + ".video", "test", 1000, 0, 1000));
        String json = ProjectCodec.encode(value).replace("\"outMs\": 1000", "\"outMs\": 2000");
        try { ProjectCodec.decode(json); fail("Accepted out of bounds trim"); } catch (org.json.JSONException expected) { /* expected */ }
    }
    @Test public void previewAndExportUseIdenticalOrderedTrimBounds() throws Exception {
        ProjectFiles files = new ProjectFiles(InstrumentationRegistry.getInstrumentation().getTargetContext()); StudioProject value = new StudioProject();
        String secondId = "dbf99c04-c954-4a54-bb84-a41a467b5a53";
        value.clips.add(new StudioProject.Clip(ID, "media/" + ID + ".video", "landscape", 10000, 1000, 3000));
        value.clips.add(new StudioProject.Clip(secondId, "media/" + secondId + ".video", "portrait silent", 8000, 2000, 6000));
        for (StudioProject.Clip clip : value.clips) try (FileOutputStream out = new FileOutputStream(files.mediaFile(clip))) { out.write(1); }
        value.move(1, 0); Composition composition = MobileExport.composition(value, files);
        assertEquals(6000, value.durationMs());
        assertEquals(secondId, composition.sequences.get(0).editedMediaItems.get(0).mediaItem.mediaId);
        assertEquals(2000, composition.sequences.get(0).editedMediaItems.get(0).mediaItem.clippingConfiguration.startPositionMs);
        assertEquals(6000, composition.sequences.get(0).editedMediaItems.get(0).mediaItem.clippingConfiguration.endPositionMs);
        assertTrue(composition.sequences.get(0).trackTypes.contains(C.TRACK_TYPE_AUDIO));
        assertTrue(composition.sequences.get(0).trackTypes.contains(C.TRACK_TYPE_VIDEO));
        for (StudioProject.Clip clip : value.clips) files.mediaFile(clip).delete();
    }
}
