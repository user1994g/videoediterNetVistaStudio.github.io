package com.netvistastudio.editor.android;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

/** Mobile-only edit. Clip instances can share media kept in app-private storage. */
public final class StudioProject {
    public static final int MAX_CLIPS = 500;
    public static final int MAX_ASSETS = 500;
    private static final String UUID_PATTERN = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
    public String title = "Untitled edit";
    public int width = 1920;
    public int height = 1080;
    /** Full-source media pool records, independent of whether a source is on the timeline. */
    public final List<Clip> assets = new ArrayList<>();
    public final List<Clip> clips = new ArrayList<>();

    /**
     * Immutable settings for one timeline instance. Position uses normalized canvas coordinates:
     * zero is centered, 1 moves one half-canvas, positive X is right and positive Y is up.
     * Opacity fades to the black
     * canvas in this single-video-track editor; it does not imply overlapping video layers.
     */
    public static final class ClipSettings {
        public final float scale;
        public final float rotationDegrees;
        public final float positionX;
        public final float positionY;
        public final float opacity;
        public final float brightness;
        public final float contrast;
        public final float saturation;

        public ClipSettings() { this(1f, 0f, 0f, 0f, 1f, 0f, 0f, 1f); }

        public ClipSettings(float scale, float rotationDegrees, float positionX, float positionY,
                            float opacity, float brightness, float contrast, float saturation) {
            requireRange("Scale", scale, 0.05f, 8f);
            requireRange("Rotation", rotationDegrees, -360f, 360f);
            requireRange("Position X", positionX, -1f, 1f);
            requireRange("Position Y", positionY, -1f, 1f);
            requireRange("Opacity", opacity, 0f, 1f);
            requireRange("Brightness", brightness, -1f, 1f);
            requireRange("Contrast", contrast, -1f, 1f);
            requireRange("Saturation", saturation, 0f, 2f);
            this.scale = scale; this.rotationDegrees = rotationDegrees;
            this.positionX = positionX; this.positionY = positionY; this.opacity = opacity;
            this.brightness = brightness; this.contrast = contrast; this.saturation = saturation;
        }

        public ClipSettings copy() {
            return new ClipSettings(scale, rotationDegrees, positionX, positionY, opacity,
                    brightness, contrast, saturation);
        }

        /**
         * Column-major 4x4 matrix on an already-fitted canvas. Aspect correction makes rotation
         * occur in pixel space, not in a distorted square of normalized device coordinates.
         * Kept Android-free so preview/export transform conventions can be tested exactly.
         */
        public float[] canvasTransformMatrix(int width, int height) {
            if (width <= 0 || height <= 0) throw new IllegalArgumentException("Canvas dimensions must be positive.");
            double radians = Math.toRadians(rotationDegrees);
            float cosine = (float) Math.cos(radians) * scale;
            float sine = (float) Math.sin(radians) * scale;
            float aspect = (float) width / height;
            return new float[]{
                    cosine, sine * aspect, 0f, 0f,
                    -sine / aspect, cosine, 0f, 0f,
                    0f, 0f, 1f, 0f,
                    positionX, positionY, 0f, 1f
            };
        }

        private static void requireRange(String name, float value, float minimum, float maximum) {
            if (!Float.isFinite(value) || value < minimum || value > maximum) {
                throw new IllegalArgumentException(name + " must be between " + minimum + " and " + maximum + ".");
            }
        }
    }

    public static final class Clip {
        /** Unique timeline/pool record identity, not necessarily the media source identity. */
        public final String id;
        public final String uri;
        public String name;
        public final long durationMs;
        public long inMs;
        public long outMs;
        public ClipSettings settings;
        public ClipAnimation animation;

        public Clip(String id, String uri, String name, long durationMs, long inMs, long outMs) {
            this(id, uri, name, durationMs, inMs, outMs, new ClipSettings());
        }

        public Clip(String id, String uri, String name, long durationMs, long inMs, long outMs,
                    ClipSettings settings) {
            this(id, uri, name, durationMs, inMs, outMs, settings, new ClipAnimation());
        }

        public Clip(String id, String uri, String name, long durationMs, long inMs, long outMs,
                    ClipSettings settings, ClipAnimation animation) {
            if (!validMediaPath(id, uri)
                    || name == null || name.length() > 512 || settings == null || animation == null || durationMs < 1
                    || durationMs > 7L * 24 * 60 * 60 * 1000) {
                throw new IllegalArgumentException("Invalid local video clip.");
            }
            this.id = id; this.uri = uri; this.name = name; this.durationMs = durationMs;
            this.settings = settings.copy();
            animation.validateDuration(durationMs); this.animation = animation.copy();
            trim(inMs, outMs);
        }

        public String sourceId() { return uri.substring("media/".length(), uri.length() - ".video".length()); }

        public void trim(long inMs, long outMs) {
            if (inMs < 0 || outMs > durationMs || outMs <= inMs) {
                throw new IllegalArgumentException("Out must be after In and within the source video.");
            }
            this.inMs = inMs; this.outMs = outMs;
        }

        public long lengthMs() { return outMs - inMs; }
        public ClipSettings settingsAtSourceMs(double sourceMs) { return animation.evaluate(settings, sourceMs); }
        public Clip copy() { return new Clip(id, uri, name, durationMs, inMs, outMs, settings, animation); }
        /** Returns a fresh full-source pool record with no timeline-only effects or trim. */
        public Clip fullSource() { return new Clip(id, uri, name, durationMs, 0, durationMs); }
    }

    public static boolean validMediaPath(String id, String uri) {
        return id != null && id.matches(UUID_PATTERN)
                && uri != null && uri.matches("media/" + UUID_PATTERN + "\\.video");
    }

    /** Unique physical sources, including unused pool assets and legacy timeline-only sources. */
    public List<Clip> sources() {
        if (assets.size() > MAX_ASSETS || clips.size() > MAX_CLIPS) {
            throw new IllegalArgumentException("Too many clips or media pool assets.");
        }
        Map<String, Clip> unique = new LinkedHashMap<>();
        for (Clip asset : assets) addSource(unique, asset);
        for (Clip clip : clips) addSource(unique, clip);
        if (unique.size() > MAX_ASSETS) throw new IllegalArgumentException("Too many source videos.");
        return new ArrayList<>(unique.values());
    }

    private static void addSource(Map<String, Clip> sources, Clip clip) {
        if (clip == null) throw new IllegalArgumentException("A source video is missing.");
        Clip source = clip.fullSource();
        Clip existing = sources.get(source.uri);
        if (existing != null && existing.durationMs != source.durationMs) {
            throw new IllegalArgumentException("Shared source duration does not match.");
        }
        if (existing == null) sources.put(source.uri, source);
    }

    /** Splits inside the retained range, using an absolute position in the original source. */
    public Clip split(int index, long sourcePositionMs) {
        Clip left = editableClip(index);
        if (sourcePositionMs <= left.inMs || sourcePositionMs >= left.outMs) {
            throw new IllegalArgumentException("Split must be inside the clip's In and Out points.");
        }
        Clip right = new Clip(freshClipId(), left.uri, left.name, left.durationMs,
                sourcePositionMs, left.outMs, left.settings, left.animation);
        left.trim(left.inMs, sourcePositionMs);
        clips.add(index + 1, right);
        return right;
    }

    /** Inserts an independent edit instance referencing the same physical source video. */
    public Clip duplicate(int index) {
        Clip original = editableClip(index);
        Clip duplicate = new Clip(freshClipId(), original.uri, original.name, original.durationMs,
                original.inMs, original.outMs, original.settings, original.animation);
        clips.add(index + 1, duplicate);
        return duplicate;
    }

    private Clip editableClip(int index) {
        if (index < 0 || index >= clips.size()) throw new IllegalArgumentException("Invalid clip position.");
        if (clips.size() >= MAX_CLIPS) throw new IllegalArgumentException("This project already has 500 clips.");
        return clips.get(index);
    }

    private String freshClipId() {
        String id;
        boolean used;
        do {
            id = UUID.randomUUID().toString(); used = false;
            for (Clip clip : clips) if (clip.id.equals(id)) { used = true; break; }
            if (!used) for (Clip asset : assets) if (asset.id.equals(id)) { used = true; break; }
        } while (used);
        return id;
    }

    public void move(int from, int to) {
        if (from < 0 || from >= clips.size() || to < 0 || to >= clips.size()) {
            throw new IllegalArgumentException("Invalid clip position.");
        }
        Clip clip = clips.remove(from); clips.add(to, clip);
    }

    /**
     * The insertion boundary to draw on the original (not yet reordered) timeline.
     * Moving forward inserts after the hovered clip; moving backward inserts
     * before it, matching move(from, to)'s final-index contract.
     */
    public long reorderBoundaryMs(int from, int to) {
        if (from < 0 || from >= clips.size() || to < 0 || to >= clips.size()) {
            throw new IllegalArgumentException("Invalid clip position.");
        }
        int boundary = from < to ? to + 1 : to;
        long time = 0;
        for (int index = 0; index < boundary; index++) time = Math.addExact(time, clips.get(index).lengthMs());
        return time;
    }

    public long durationMs() {
        long total = 0;
        for (Clip clip : clips) total = Math.addExact(total, clip.lengthMs());
        return total;
    }

    public StudioProject copy() {
        StudioProject value = new StudioProject();
        value.title = title; value.width = width; value.height = height;
        for (Clip asset : assets) value.assets.add(asset.copy());
        for (Clip clip : clips) value.clips.add(clip.copy());
        return value;
    }
}
