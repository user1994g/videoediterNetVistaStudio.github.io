package com.netvistastudio.editor.android;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

/** Mobile-only cut list. Media identifiers resolve only inside app-private storage. */
public final class StudioProject {
    public static final int MAX_CLIPS = 500;
    public String title = "Untitled edit";
    public int width = 1920;
    public int height = 1080;
    public final List<Clip> clips = new ArrayList<>();

    public static final class Clip {
        public final String id;
        public String uri;
        public String name;
        public final long durationMs;
        public long inMs;
        public long outMs;

        public Clip(String id, String uri, String name, long durationMs, long inMs, long outMs) {
            if (!validMediaPath(id, uri)
                    || name == null || name.length() > 512 || durationMs < 1
                    || durationMs > 7L * 24 * 60 * 60 * 1000) {
                throw new IllegalArgumentException("Invalid local video clip.");
            }
            this.id = id; this.uri = uri; this.name = name; this.durationMs = durationMs;
            trim(inMs, outMs);
        }

        public void trim(long inMs, long outMs) {
            if (inMs < 0 || outMs > durationMs || outMs <= inMs) {
                throw new IllegalArgumentException("Out must be after In and within the source video.");
            }
            this.inMs = inMs; this.outMs = outMs;
        }

        public long lengthMs() { return outMs - inMs; }
        public Clip copy() { return new Clip(id, uri, name, durationMs, inMs, outMs); }
    }

    public static boolean validMediaPath(String id, String uri) {
        if (id == null || !id.matches("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")) return false;
        return ("media/" + id + ".video").equals(uri);
    }

    public void move(int from, int to) {
        if (from < 0 || from >= clips.size() || to < 0 || to >= clips.size()) {
            throw new IllegalArgumentException("Invalid clip position.");
        }
        Clip clip = clips.remove(from); clips.add(to, clip);
    }

    public long durationMs() {
        long total = 0;
        for (Clip clip : clips) total = Math.addExact(total, clip.lengthMs());
        return total;
    }

    public StudioProject copy() {
        StudioProject value = new StudioProject();
        value.title = title; value.width = width; value.height = height;
        for (Clip clip : clips) value.clips.add(clip.copy());
        return value;
    }
}
