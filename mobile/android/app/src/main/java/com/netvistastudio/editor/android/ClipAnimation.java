package com.netvistastudio.editor.android;

import java.util.ArrayList;
import java.util.Collections;
import java.util.EnumMap;
import java.util.List;
import java.util.Map;

/** Immutable, bounded source-time curves. Trimming/splitting never retimes animation. */
public final class ClipAnimation {
    public static final int MAX_POINTS_PER_PROPERTY = 2000;
    public static final int MAX_POINTS_PER_CLIP = 10000;
    public static final long MAX_SOURCE_MS = 7L * 24 * 60 * 60 * 1000;
    public enum Property {
        SCALE("Scale / Zoom", .05f, 8f), ROTATION("Rotation", -360f, 360f),
        POSITION_X("Position X", -1f, 1f), POSITION_Y("Position Y", -1f, 1f),
        OPACITY("Opacity", 0f, 1f), BRIGHTNESS("Brightness", -1f, 1f),
        CONTRAST("Contrast", -1f, 1f), SATURATION("Saturation", 0f, 2f);
        public final String label;
        public final float minimum, maximum;
        Property(String label, float minimum, float maximum) { this.label = label; this.minimum = minimum; this.maximum = maximum; }
        public void validate(float value) {
            if (!Float.isFinite(value) || value < minimum || value > maximum) throw new IllegalArgumentException(label + " keyframe value is outside its valid range.");
        }
        public float value(StudioProject.ClipSettings settings) {
            switch (this) {
                case SCALE: return settings.scale; case ROTATION: return settings.rotationDegrees;
                case POSITION_X: return settings.positionX; case POSITION_Y: return settings.positionY;
                case OPACITY: return settings.opacity; case BRIGHTNESS: return settings.brightness;
                case CONTRAST: return settings.contrast; default: return settings.saturation;
            }
        }
    }
    /** The left keyframe controls interpolation up to the next keyframe. */
    public enum Curve { LINEAR, HOLD, EASE_IN, EASE_OUT, EASE_IN_OUT }
    public static final class Keyframe {
        public final long sourceMs;
        public final float value;
        public final Curve curve;
        public Keyframe(long sourceMs, float value, Curve curve) {
            if (sourceMs < 0 || sourceMs > MAX_SOURCE_MS || !Float.isFinite(value) || curve == null) throw new IllegalArgumentException("Invalid animation keyframe.");
            this.sourceMs = sourceMs; this.value = value; this.curve = curve;
        }
    }
    private final Map<Property, List<Keyframe>> tracks;
    public ClipAnimation() { this(Collections.emptyMap()); }
    public ClipAnimation(Map<Property, List<Keyframe>> input) {
        if (input == null || input.size() > Property.values().length) throw new IllegalArgumentException("Invalid animation tracks.");
        EnumMap<Property, List<Keyframe>> validated = new EnumMap<>(Property.class); int total = 0;
        for (Map.Entry<Property, List<Keyframe>> entry : input.entrySet()) {
            Property property = entry.getKey(); List<Keyframe> points = entry.getValue();
            if (property == null || points == null || points.size() > MAX_POINTS_PER_PROPERTY) throw new IllegalArgumentException("Too many animation keyframes.");
            total += points.size(); if (total > MAX_POINTS_PER_CLIP) throw new IllegalArgumentException("A clip supports at most 10,000 animation keyframes.");
            ArrayList<Keyframe> copy = new ArrayList<>(points.size()); long previous = -1;
            for (Keyframe point : points) {
                if (point == null || point.sourceMs <= previous) throw new IllegalArgumentException("Keyframe times must be unique and ordered.");
                property.validate(point.value); copy.add(new Keyframe(point.sourceMs, point.value, point.curve)); previous = point.sourceMs;
            }
            if (!copy.isEmpty()) validated.put(property, Collections.unmodifiableList(copy));
        }
        tracks = Collections.unmodifiableMap(validated);
    }
    public boolean isEmpty() { return tracks.isEmpty(); }
    public List<Keyframe> points(Property property) { return tracks.getOrDefault(property, Collections.emptyList()); }
    public ClipAnimation copy() { return new ClipAnimation(tracks); }
    public void validateDuration(long durationMs) {
        for (List<Keyframe> points : tracks.values()) for (Keyframe point : points) {
            if (point.sourceMs > durationMs) throw new IllegalArgumentException("Keyframe is outside its source video.");
        }
    }
    public ClipAnimation withKeyframe(Property property, long sourceMs, float value, Curve curve) {
        if (property == null) throw new IllegalArgumentException("Choose an animation property.");
        property.validate(value); Keyframe next = new Keyframe(sourceMs, value, curve);
        ArrayList<Keyframe> points = new ArrayList<>(points(property)); int index = 0;
        while (index < points.size() && points.get(index).sourceMs < sourceMs) index++;
        if (index < points.size() && points.get(index).sourceMs == sourceMs) points.set(index, next); else points.add(index, next);
        EnumMap<Property, List<Keyframe>> changed = new EnumMap<>(Property.class); changed.putAll(tracks); changed.put(property, points);
        return new ClipAnimation(changed);
    }
    public ClipAnimation withoutKeyframe(Property property, long sourceMs) {
        ArrayList<Keyframe> points = new ArrayList<>(points(property)); points.removeIf(point -> point.sourceMs == sourceMs);
        EnumMap<Property, List<Keyframe>> changed = new EnumMap<>(Property.class); changed.putAll(tracks); changed.put(property, points);
        return new ClipAnimation(changed);
    }
    public ClipAnimation withoutProperty(Property property) {
        EnumMap<Property, List<Keyframe>> changed = new EnumMap<>(Property.class); changed.putAll(tracks); changed.remove(property);
        return new ClipAnimation(changed);
    }
    public float valueAt(Property property, double sourceMs, float fallback) {
        if (!Double.isFinite(sourceMs)) throw new IllegalArgumentException("Animation time must be finite.");
        List<Keyframe> points = points(property); if (points.isEmpty()) return fallback;
        if (sourceMs <= points.get(0).sourceMs) return points.get(0).value;
        int low = 0, high = points.size() - 1;
        if (sourceMs >= points.get(high).sourceMs) return points.get(high).value;
        while (high - low > 1) { int middle = (low + high) / 2; if (points.get(middle).sourceMs <= sourceMs) low = middle; else high = middle; }
        Keyframe left = points.get(low), right = points.get(high);
        if (left.curve == Curve.HOLD) return left.value;
        double progress = (sourceMs - left.sourceMs) / (right.sourceMs - left.sourceMs);
        if (left.curve == Curve.EASE_IN) progress = progress * progress;
        else if (left.curve == Curve.EASE_OUT) progress = 1 - (1 - progress) * (1 - progress);
        else if (left.curve == Curve.EASE_IN_OUT) progress = progress * progress * (3 - 2 * progress);
        // Double interpolation prevents float rounding from exceeding validated endpoint ranges.
        return (float) (left.value + ((double) right.value - left.value) * progress);
    }
    public StudioProject.ClipSettings evaluate(StudioProject.ClipSettings base, double sourceMs) {
        if (isEmpty()) return base;
        return new StudioProject.ClipSettings(valueAt(Property.SCALE, sourceMs, base.scale),
                valueAt(Property.ROTATION, sourceMs, base.rotationDegrees), valueAt(Property.POSITION_X, sourceMs, base.positionX),
                valueAt(Property.POSITION_Y, sourceMs, base.positionY), valueAt(Property.OPACITY, sourceMs, base.opacity),
                valueAt(Property.BRIGHTNESS, sourceMs, base.brightness), valueAt(Property.CONTRAST, sourceMs, base.contrast),
                valueAt(Property.SATURATION, sourceMs, base.saturation));
    }
}
