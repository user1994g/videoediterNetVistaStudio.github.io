package com.netvistastudio.editor.android;

import org.junit.Test;
import static org.junit.Assert.*;

public final class StudioProjectTest {
    private static final String ID = "fe813cc1-e815-4da4-a520-613366184629";
    private static StudioProject.Clip clip(long in, long out) {
        return new StudioProject.Clip(ID, "media/" + ID + ".video", "Clip", 10000, in, out);
    }
    @Test public void trimKeepsOnlySpecifiedRange() {
        StudioProject.Clip clip = clip(1200, 5600);
        assertEquals(4400, clip.lengthMs()); clip.trim(0, 10000); assertEquals(10000, clip.lengthMs());
    }
    @Test(expected = IllegalArgumentException.class) public void rejectsNegativeTrim() { clip(-1, 5000); }
    @Test(expected = IllegalArgumentException.class) public void rejectsReversedTrim() { clip(5000, 4999); }
    @Test(expected = IllegalArgumentException.class) public void rejectsZeroLengthTrim() { clip(5000, 5000); }
    @Test(expected = IllegalArgumentException.class) public void rejectsPastSourceEnd() { clip(0, 10001); }
    @Test public void reorderPreservesSequenceDurationAndIdentity() {
        StudioProject value = new StudioProject(); value.clips.add(clip(0, 2000)); value.clips.add(clip(1000, 6000));
        StudioProject.Clip first = value.clips.get(0); value.move(0, 1);
        assertSame(first, value.clips.get(1)); assertEquals(7000, value.durationMs());
    }
    @Test public void forwardDropMarkerIsAfterTargetAndBackwardMarkerIsBeforeTarget() {
        StudioProject value = reorderFixture();
        assertEquals("Forward A→C draws after C, not before it", 9000, value.reorderBoundaryMs(0, 2));
        assertEquals("Forward A→B draws after B", 5000, value.reorderBoundaryMs(0, 1));
        assertEquals("Backward C→A draws before A", 0, value.reorderBoundaryMs(2, 0));
        assertEquals("Backward C→B draws before B", 2000, value.reorderBoundaryMs(2, 1));
        assertEquals("No-op B→B retains B's original start", 2000, value.reorderBoundaryMs(1, 1));
    }
    @Test public void everyDropBoundaryAgreesWithActualFinalSequencePlacement() {
        for (int from = 0; from < 3; from++) for (int to = 0; to < 3; to++) {
            StudioProject value = reorderFixture();
            StudioProject.Clip moving = value.clips.get(from);
            long drawnBoundary = value.reorderBoundaryMs(from, to);
            // Removing an earlier clip shifts its forward insertion boundary left
            // by precisely that clip's duration; backward boundaries do not shift.
            long expectedFinalStart = drawnBoundary - (from < to ? moving.lengthMs() : 0);
            value.move(from, to);
            long actualFinalStart = 0;
            for (int index = 0; index < to; index++) actualFinalStart += value.clips.get(index).lengthMs();
            assertEquals("Marker matches final sequence placement " + from + "→" + to,
                    expectedFinalStart, actualFinalStart);
            assertSame(moving, value.clips.get(to));
            assertEquals(9000, value.durationMs());
        }
    }
    @Test(expected = IllegalArgumentException.class) public void dropBoundaryRejectsInvalidTarget() {
        reorderFixture().reorderBoundaryMs(0, 3);
    }
    private static StudioProject reorderFixture() {
        StudioProject value = new StudioProject();
        for (int index = 0; index < 3; index++) {
            String id = "fe813cc1-e815-4da4-a520-61336618462" + index;
            long duration = (index + 2) * 1000L;
            value.clips.add(new StudioProject.Clip(id, "media/" + id + ".video",
                    Character.toString((char) ('A' + index)), duration, 0, duration));
        }
        return value;
    }
    @Test public void exportSnapshotIsIndependentOfLaterEdits() {
        StudioProject value = new StudioProject(); value.clips.add(clip(0, 4000));
        StudioProject snapshot = value.copy(); value.clips.get(0).trim(1000, 2000); value.clips.clear();
        assertEquals(4000, snapshot.durationMs()); assertEquals(1, snapshot.clips.size());
    }
    @Test public void unsafePathsAndExternalUrisAreRejected() {
        assertFalse(StudioProject.validMediaPath(ID, "../../private/video.mp4"));
        assertFalse(StudioProject.validMediaPath(ID, "media/../" + ID + ".video"));
        assertFalse(StudioProject.validMediaPath(ID, "file:///sdcard/movie.mp4"));
        assertFalse(StudioProject.validMediaPath(ID, "https://example.com/movie.mp4"));
        assertFalse(StudioProject.validMediaPath(ID, "content://other/video"));
        assertFalse(StudioProject.validMediaPath(ID, "media/" + ID + ".video/extra"));
        assertTrue(StudioProject.validMediaPath(ID, "media/" + ID + ".video"));
    }
    @Test(expected = IllegalArgumentException.class) public void malformedIdCannotResolveAPath() {
        new StudioProject.Clip("../private", "media/../private.video", "Video", 100, 0, 100);
    }
}
