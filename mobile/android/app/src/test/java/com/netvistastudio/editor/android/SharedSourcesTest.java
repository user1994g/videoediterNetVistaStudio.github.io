package com.netvistastudio.editor.android;

import java.util.UUID;
import org.junit.Test;
import static org.junit.Assert.*;

public final class SharedSourcesTest {
    private static final String ID = "fe813cc1-e815-4da4-a520-613366184629";
    private static StudioProject.Clip clip() {
        return new StudioProject.Clip(ID, "media/" + ID + ".video", "Source", 10000, 1200, 8000,
                new StudioProject.ClipSettings(1.5f, 20f, 0.25f, -0.5f, 0.8f, 0.1f, -0.2f, 1.2f));
    }

    @Test public void splittingSharesOneSourceWithUniqueEditIdentityAndIndependentSettings() {
        StudioProject project = new StudioProject(); project.clips.add(clip());
        StudioProject.Clip right = project.split(0, 3500);
        StudioProject.Clip left = project.clips.get(0);
        assertEquals(ID, left.id); assertNotEquals(left.id, right.id);
        assertEquals(left.uri, right.uri); assertEquals(ID, right.sourceId());
        assertEquals(1200, left.inMs); assertEquals(3500, left.outMs);
        assertEquals(3500, right.inMs); assertEquals(8000, right.outMs);
        assertEquals(6800, project.durationMs()); assertEquals(1, project.sources().size());
        assertNotSame(left.settings, right.settings); assertEquals(1.5f, right.settings.scale, 0f);
        left.settings = new StudioProject.ClipSettings();
        assertEquals("Split edits do not share later inspector changes", 1.5f, right.settings.scale, 0f);
    }

    @Test public void duplicateKeepsTrimAndEffectsButUsesIndependentTimelineIdentity() {
        StudioProject project = new StudioProject(); project.clips.add(clip());
        StudioProject.Clip duplicate = project.duplicate(0);
        assertSame(duplicate, project.clips.get(1)); assertNotEquals(ID, duplicate.id);
        assertEquals(1200, duplicate.inMs); assertEquals(8000, duplicate.outMs);
        assertEquals(ID, duplicate.sourceId()); assertEquals(13600, project.durationMs());
        assertEquals(0.8f, duplicate.settings.opacity, 0f);
        duplicate.trim(2000, 4000);
        assertEquals("Original trim is unchanged", 6800, project.clips.get(0).lengthMs());
    }

    @Test public void boundarySplitIsRejectedWithoutMutatingTimeline() {
        StudioProject project = new StudioProject(); project.clips.add(clip());
        for (long position : new long[]{0, 1200, 8000, 10000}) {
            try { project.split(0, position); fail("Accepted split outside retained clip."); }
            catch (IllegalArgumentException expected) { /* expected */ }
            assertEquals(1, project.clips.size()); assertEquals(6800, project.durationMs());
        }
    }

    @Test public void clipIdAndSourceIdAreIndependentButBothMustBeSafeUuids() {
        String instance = UUID.randomUUID().toString();
        assertTrue(StudioProject.validMediaPath(instance, "media/" + ID + ".video"));
        assertFalse(StudioProject.validMediaPath("../outside", "media/" + ID + ".video"));
        assertFalse(StudioProject.validMediaPath(instance, "media/../" + ID + ".video"));
        assertFalse(StudioProject.validMediaPath(instance, "media/" + ID + ".video/extra"));
        assertFalse(StudioProject.validMediaPath(instance, "media/" + ID.toUpperCase() + ".video"));
    }

    @Test public void unusedAssetsSurviveTimelineRemovalAndSnapshotCopy() {
        StudioProject project = new StudioProject(); StudioProject.Clip timeline = clip();
        project.assets.add(timeline.fullSource()); project.clips.add(timeline);
        StudioProject copy = project.copy(); project.clips.clear(); project.assets.clear();
        assertEquals(1, copy.assets.size()); copy.clips.clear();
        assertEquals(1, copy.sources().size()); assertEquals(0, copy.durationMs());
        assertEquals(0, copy.assets.get(0).inMs); assertEquals(10000, copy.assets.get(0).outMs);
        assertEquals("Pool has no timeline-specific effects", 1f, copy.assets.get(0).settings.scale, 0f);
    }

    @Test public void legacySourceFallbackIsFullRangeAndDeduplicated() {
        StudioProject project = new StudioProject(); project.clips.add(clip()); project.duplicate(0);
        StudioProject.Clip source = project.sources().get(0);
        assertEquals(1, project.sources().size()); assertEquals(0, source.inMs);
        assertEquals(10000, source.outMs); assertEquals(1f, source.settings.saturation, 0f);
    }

    @Test(expected = IllegalArgumentException.class) public void inconsistentSharedSourceDurationIsRejected() {
        StudioProject project = new StudioProject(); project.clips.add(clip());
        project.assets.add(new StudioProject.Clip(UUID.randomUUID().toString(), "media/" + ID + ".video", "Source", 8000, 0, 8000));
        project.sources();
    }

    @Test public void clipLimitCannotBeExceededByDuplicateOrSplit() {
        StudioProject project = new StudioProject();
        for (int i = 0; i < StudioProject.MAX_CLIPS; i++) {
            project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), "media/" + ID + ".video", "Source", 10000, 0, 10000));
        }
        try { project.duplicate(0); fail("Exceeded limit by duplication"); }
        catch (IllegalArgumentException expected) { /* expected */ }
        try { project.split(0, 4000); fail("Exceeded limit by splitting"); }
        catch (IllegalArgumentException expected) { /* expected */ }
        assertEquals(StudioProject.MAX_CLIPS, project.clips.size());
        assertEquals(10000, project.clips.get(0).lengthMs());
    }
}
