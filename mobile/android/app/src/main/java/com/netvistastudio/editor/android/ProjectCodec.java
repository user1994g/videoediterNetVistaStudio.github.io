package com.netvistastudio.editor.android;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.util.HashSet;
import java.util.Set;

public final class ProjectCodec {
    public static final int MAX_BYTES = 2 * 1024 * 1024;
    private ProjectCodec() {}

    public static String encode(StudioProject project) throws JSONException {
        JSONObject value = new JSONObject();
        value.put("format", "netvista-mobile"); value.put("version", 1);
        value.put("platform", "android"); value.put("title", project.title);
        value.put("width", project.width); value.put("height", project.height);
        JSONArray clips = new JSONArray();
        for (StudioProject.Clip clip : project.clips) {
            JSONObject item = new JSONObject();
            item.put("id", clip.id); item.put("uri", clip.uri); item.put("name", clip.name);
            item.put("durationMs", clip.durationMs); item.put("inMs", clip.inMs); item.put("outMs", clip.outMs);
            clips.put(item);
        }
        value.put("clips", clips);
        return value.toString(2);
    }

    public static StudioProject decode(String text) throws JSONException {
        if (text.length() > MAX_BYTES) throw new JSONException("Project file is too large.");
        JSONObject value = new JSONObject(text);
        if (!"netvista-mobile".equals(value.getString("format")) || value.getInt("version") != 1
                || !"android".equals(value.getString("platform"))) {
            throw new JSONException("This is not a supported Android mobile project. Desktop and iPad projects are different formats.");
        }
        StudioProject result = new StudioProject();
        result.title = value.getString("title");
        if (result.title.length() > 200) throw new JSONException("Project title is too long.");
        result.width = value.getInt("width"); result.height = value.getInt("height");
        if (!((result.width == 1920 && result.height == 1080)
                || (result.width == 1280 && result.height == 720)
                || (result.width == 1080 && result.height == 1920))) {
            throw new JSONException("Unsupported mobile export size.");
        }
        JSONArray clips = value.getJSONArray("clips");
        if (clips.length() > StudioProject.MAX_CLIPS) throw new JSONException("Too many clips.");
        Set<String> ids = new HashSet<>();
        for (int i = 0; i < clips.length(); i++) {
            JSONObject clip = clips.getJSONObject(i);
            try {
                StudioProject.Clip item = new StudioProject.Clip(clip.getString("id"), clip.getString("uri"),
                        clip.getString("name"), clip.getLong("durationMs"), clip.getLong("inMs"), clip.getLong("outMs"));
                if (!ids.add(item.id)) throw new IllegalArgumentException("Duplicate clip ID.");
                result.clips.add(item);
            } catch (IllegalArgumentException e) { throw new JSONException(e.getMessage()); }
        }
        return result;
    }
}
