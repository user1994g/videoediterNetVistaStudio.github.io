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
