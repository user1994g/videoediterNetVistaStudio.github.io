package com.netvistastudio.editor.android;

import android.content.Context;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** A portable project contains each physical source once, not once per edit instance. */
@RunWith(AndroidJUnit4.class)
public final class SharedProjectArchiveTest {
    @Test public void archiveKeepsUnusedPoolAndSharedSourcesWithIndependentEffects() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        Context testContext = InstrumentationRegistry.getInstrumentation().getContext();
        ProjectFiles files = new ProjectFiles(context);
        StudioProject project = new StudioProject(); StudioProject loaded = null;
        StudioProject.Clip used = source("Landscape", 3000), unused = source("Unused portrait", 3000);
        project.assets.add(used); project.assets.add(unused);
        project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), used.uri, used.name, 3000, 100, 1800,
                new StudioProject.ClipSettings(0.75f, 90f, 0.3f, -0.2f, 0.6f, 0.2f, -0.3f, 0.5f)));
        project.duplicate(0); project.clips.get(1).trim(1800, 2600);
        project.clips.get(1).settings = new StudioProject.ClipSettings(1.2f, -45f, -0.4f, 0.6f, 1f, -0.2f, 0.4f, 1.5f);
        project.clips.get(1).animation = new ClipAnimation().withKeyframe(ClipAnimation.Property.OPACITY, 100, 0, ClipAnimation.Curve.HOLD)
                .withKeyframe(ClipAnimation.Property.OPACITY, 1200, 1, ClipAnimation.Curve.LINEAR);
        try {
            copyFixture(testContext, files, used, "red-silent-landscape.mp4");
            copyFixture(testContext, files, unused, "blue-audio-portrait.mp4");
            ByteArrayOutputStream output = new ByteArrayOutputStream(); files.saveArchive(project, output);
            Set<String> entries = new HashSet<>();
            try (ZipInputStream zip = new ZipInputStream(new ByteArrayInputStream(output.toByteArray()))) {
                ZipEntry entry;
                while ((entry = zip.getNextEntry()) != null) { assertTrue(entries.add(entry.getName())); zip.closeEntry(); }
            }
            assertEquals(3, entries.size()); assertTrue(entries.contains("project.json"));
            assertTrue(entries.contains(used.uri)); assertTrue(entries.contains(unused.uri));
            loaded = files.loadArchive(new ByteArrayInputStream(output.toByteArray()));
            assertEquals(2, loaded.assets.size()); assertEquals(2, loaded.clips.size()); assertEquals(2500, loaded.durationMs());
            assertEquals(loaded.clips.get(0).uri, loaded.clips.get(1).uri);
            assertNotEquals(used.uri, loaded.clips.get(0).uri);
            assertNotEquals(loaded.clips.get(0).id, loaded.clips.get(1).id);
            assertEquals(files.mediaFile(loaded.clips.get(0)), files.mediaFile(loaded.clips.get(1)));
            assertEquals(0.75f, loaded.clips.get(0).settings.scale, 0f);
            assertEquals(90f, loaded.clips.get(0).settings.rotationDegrees, 0f);
            assertEquals(-0.2f, loaded.clips.get(0).settings.positionY, 0f);
            assertEquals(0.6f, loaded.clips.get(0).settings.opacity, 0f);
            assertEquals(0.2f, loaded.clips.get(0).settings.brightness, 0f);
            assertEquals(-0.3f, loaded.clips.get(0).settings.contrast, 0f);
            assertEquals(0.5f, loaded.clips.get(0).settings.saturation, 0f);
            assertEquals(1.2f, loaded.clips.get(1).settings.scale, 0f);
            assertEquals(1.5f, loaded.clips.get(1).settings.saturation, 0f);
            assertTrue(loaded.clips.get(0).animation.isEmpty());
            assertEquals(2, loaded.clips.get(1).animation.points(ClipAnimation.Property.OPACITY).size());
            assertEquals(100, loaded.clips.get(1).animation.points(ClipAnimation.Property.OPACITY).get(0).sourceMs);
            assertEquals(ClipAnimation.Curve.HOLD, loaded.clips.get(1).animation.points(ClipAnimation.Property.OPACITY).get(0).curve);
            assertEquals(0, loaded.clips.get(1).settingsAtSourceMs(1000).opacity, 0);
            assertEquals(1, loaded.clips.get(1).settingsAtSourceMs(1800).opacity, 0);
            for (StudioProject.Clip asset : loaded.assets) {
                assertTrue(files.mediaFile(asset).isFile()); assertEquals(0, asset.inMs); assertEquals(asset.durationMs, asset.outMs);
                assertEquals(1f, asset.settings.scale, 0f); assertEquals(0f, asset.settings.brightness, 0f);
                assertTrue(asset.animation.isEmpty());
            }
            files.mediaFile(used).delete(); files.mediaFile(unused).delete();
            for (StudioProject.Clip asset : loaded.assets) assertTrue("Portable copies must not depend on originals", files.mediaFile(asset).length() > 0);
        } finally {
            for (StudioProject.Clip asset : project.sources()) files.mediaFile(asset).delete();
            if (loaded != null) for (StudioProject.Clip asset : loaded.sources()) files.mediaFile(asset).delete();
        }
    }
    private static StudioProject.Clip source(String name, long duration) {
        String id = UUID.randomUUID().toString(); return new StudioProject.Clip(id, "media/" + id + ".video", name, duration, 0, duration);
    }
    private static void copyFixture(Context context, ProjectFiles files, StudioProject.Clip clip, String name) throws Exception {
        try (InputStream input = context.getAssets().open("export-fixtures/" + name); FileOutputStream output = new FileOutputStream(files.mediaFile(clip))) {
            ProjectFiles.copy(input, output, ProjectFiles.MAX_VIDEO_BYTES);
        }
    }
}
