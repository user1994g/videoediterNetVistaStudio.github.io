package com.netvistastudio.editor.android;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.util.HashSet;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.List;
import java.util.Set;
import java.nio.charset.StandardCharsets;

public final class ProjectCodec {
    public static final int MAX_BYTES = 2 * 1024 * 1024;
    private ProjectCodec() {}

    public static String encode(StudioProject project) throws JSONException {
        if (project == null) throw new JSONException("Project is missing.");
        validateHeader(project);
        JSONObject value = new JSONObject();
        value.put("format", "netvista-mobile"); value.put("version", 3);
        value.put("platform", "android"); value.put("title", project.title);
        value.put("width", project.width); value.put("height", project.height);
        try {
            // Canonical full-source pool includes legacy timeline-only media, once per source.
            value.put("assets", encodeClips(project.sources()));
            value.put("clips", encodeClips(project.clips));
        } catch (IllegalArgumentException e) { throw new JSONException(e.getMessage()); }
        String text = value.toString(2);
        if (text.length() > MAX_BYTES || text.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) throw new JSONException("Project file is too large (maximum 2 MiB UTF-8).");
        return text;
    }

    private static JSONArray encodeClips(List<StudioProject.Clip> clips) throws JSONException {
        if (clips.size() > StudioProject.MAX_CLIPS) throw new JSONException("Too many clips.");
        JSONArray result = new JSONArray();
        Set<String> ids = new HashSet<>();
        for (StudioProject.Clip clip : clips) {
            if (clip == null) throw new IllegalArgumentException("Clip is missing.");
            StudioProject.Clip valid = clip.copy();
            if (!ids.add(valid.id)) throw new IllegalArgumentException("Duplicate clip ID.");
            JSONObject item = new JSONObject();
            item.put("id", valid.id); item.put("uri", valid.uri); item.put("name", valid.name);
            item.put("durationMs", valid.durationMs); item.put("inMs", valid.inMs); item.put("outMs", valid.outMs);
            StudioProject.ClipSettings settings = valid.settings;
            JSONObject effect = new JSONObject();
            effect.put("scale", settings.scale); effect.put("rotationDegrees", settings.rotationDegrees);
            effect.put("positionX", settings.positionX); effect.put("positionY", settings.positionY);
            effect.put("opacity", settings.opacity); effect.put("brightness", settings.brightness);
            effect.put("contrast", settings.contrast); effect.put("saturation", settings.saturation);
            item.put("settings", effect);
            JSONObject animation = new JSONObject();
            for (ClipAnimation.Property property : ClipAnimation.Property.values()) {
                if (valid.animation.points(property).isEmpty()) continue;
                JSONArray points = new JSONArray();
                for (ClipAnimation.Keyframe point : valid.animation.points(property)) {
                    JSONObject key = new JSONObject(); key.put("sourceMs", point.sourceMs);
                    key.put("value", point.value); key.put("curve", point.curve.name()); points.put(key);
                }
                animation.put(property.name(), points);
            }
            if (animation.length() > 0) item.put("animation", animation);
            result.put(item);
        }
        return result;
    }

    public static StudioProject decode(String text) throws JSONException {
        if (text == null || text.length() > MAX_BYTES || text.getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) throw new JSONException("Project file is missing or exceeds 2 MiB UTF-8.");
        JSONObject value = new JSONObject(text);
        long version = integer(value, "version");
        if (!"netvista-mobile".equals(value.getString("format")) || (version < 1 || version > 3)
                || !"android".equals(value.getString("platform"))) {
            throw new JSONException("This is not a supported Android mobile project. Desktop and iPad projects are different formats.");
        }
        StudioProject result = new StudioProject();
        result.title = value.getString("title");
        long width = integer(value, "width"), height = integer(value, "height");
        if (width < 0 || width > Integer.MAX_VALUE || height < 0 || height > Integer.MAX_VALUE) throw new JSONException("Invalid canvas size.");
        result.width = (int) width; result.height = (int) height;
        validateHeader(result);
        decodeClips(value.getJSONArray("clips"), result.clips, StudioProject.MAX_CLIPS);
        if (value.has("assets")) decodeClips(value.getJSONArray("assets"), result.assets, StudioProject.MAX_ASSETS);
        try {
            List<StudioProject.Clip> sources = result.sources();
            // Version 1 has no pool. Missing pool records in additive project revisions also
            // become full-range, default-settings sources so deleting edits does not lose media.
            result.assets.clear(); result.assets.addAll(sources);
        } catch (IllegalArgumentException e) { throw new JSONException(e.getMessage()); }
        return result;
    }

    private static void validateHeader(StudioProject project) throws JSONException {
        if (project.title == null || project.title.length() > 200) throw new JSONException("Project title is missing or too long.");
        if (!((project.width == 1920 && project.height == 1080)
                || (project.width == 1280 && project.height == 720)
                || (project.width == 1080 && project.height == 1920))) {
            throw new JSONException("Unsupported mobile export size.");
        }
    }

    private static void decodeClips(JSONArray clips, List<StudioProject.Clip> target, int limit) throws JSONException {
        if (clips.length() > limit) throw new JSONException("Too many clips or media pool assets.");
        Set<String> ids = new HashSet<>();
        for (int i = 0; i < clips.length(); i++) {
            JSONObject clip = clips.getJSONObject(i);
            try {
                StudioProject.Clip item = new StudioProject.Clip(clip.getString("id"), clip.getString("uri"),
                        clip.getString("name"), integer(clip, "durationMs"), integer(clip, "inMs"), integer(clip, "outMs"),
                        clip.has("settings") ? decodeSettings(clip.getJSONObject("settings")) : new StudioProject.ClipSettings(),
                        clip.has("animation") ? decodeAnimation(clip.getJSONObject("animation")) : new ClipAnimation());
                if (!ids.add(item.id)) throw new IllegalArgumentException("Duplicate clip ID.");
                target.add(item);
            } catch (IllegalArgumentException e) { throw new JSONException(e.getMessage()); }
        }
    }

    private static StudioProject.ClipSettings decodeSettings(JSONObject settings) throws JSONException {
        return new StudioProject.ClipSettings(number(settings, "scale", 1f), number(settings, "rotationDegrees", 0f),
                number(settings, "positionX", 0f), number(settings, "positionY", 0f), number(settings, "opacity", 1f),
                number(settings, "brightness", 0f), number(settings, "contrast", 0f), number(settings, "saturation", 1f));
    }

    private static ClipAnimation decodeAnimation(JSONObject value) throws JSONException {
        if (value.length() > ClipAnimation.Property.values().length) throw new JSONException("Too many animation properties.");
        EnumMap<ClipAnimation.Property, List<ClipAnimation.Keyframe>> tracks = new EnumMap<>(ClipAnimation.Property.class);
        java.util.Iterator<String> keys = value.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            try {
                ClipAnimation.Property property = ClipAnimation.Property.valueOf(key);
                JSONArray points = value.getJSONArray(key);
                if (points.length() > ClipAnimation.MAX_POINTS_PER_PROPERTY) throw new IllegalArgumentException("Too many animation keyframes.");
                ArrayList<ClipAnimation.Keyframe> decoded = new ArrayList<>(points.length());
                for (int index = 0; index < points.length(); index++) {
                    JSONObject point = points.getJSONObject(index);
                    // Required fields: never substitute a neutral value for corrupt animation.
                    if (!point.has("value")) throw new JSONException("Keyframe value is missing.");
                    decoded.add(new ClipAnimation.Keyframe(integer(point, "sourceMs"), number(point, "value", 0),
                            ClipAnimation.Curve.valueOf(point.getString("curve"))));
                }
                tracks.put(property, decoded);
            } catch (IllegalArgumentException e) { throw new JSONException("Invalid animation: " + e.getMessage()); }
        }
        return new ClipAnimation(tracks);
    }

    private static float number(JSONObject object, String key, float defaultValue) throws JSONException {
        if (!object.has(key)) return defaultValue;
        Object value = object.get(key);
        if (!(value instanceof Number)) throw new JSONException(key + " must be a number.");
        float number = ((Number) value).floatValue();
        if (!Float.isFinite(number)) throw new JSONException(key + " must be finite.");
        return number;
    }

    private static long integer(JSONObject object, String key) throws JSONException {
        Object value = object.get(key);
        if (!(value instanceof Integer) && !(value instanceof Long)) throw new JSONException(key + " must be an integer.");
        return ((Number) value).longValue();
    }
}
