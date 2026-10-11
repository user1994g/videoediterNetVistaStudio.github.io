package com.netvistastudio.editor.android;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.EnumMap;
import java.util.List;
import java.util.UUID;
import static org.junit.Assert.*;

/** Otherwise-valid saved projects with precisely bounded canonical manifest headroom. */
final class ProjectBudgetFixtures {
    private ProjectBudgetFixtures() {}
    static int bytes(StudioProject project) throws Exception { return ProjectCodec.encode(project).getBytes(StandardCharsets.UTF_8).length; }
    static StudioProject nearLimit(StudioProject base) throws Exception {
        StudioProject project = base.copy(); StudioProject.Clip source = project.clips.get(0).copy();
        source.settings = new StudioProject.ClipSettings(1, 0, 0, 0, .8f, 0, 0, 1);
        source.animation = keys(source.settings, true); project.clips.clear(); project.clips.add(source);
        ClipAnimation maximum = keys(source.settings, false);
        for (int index = 0; index < 3; index++) project.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), source.uri,
                source.name, source.durationMs, source.inMs, source.outMs, source.settings, maximum));
        String fullName = repeat('\u754c', 512);
        while (project.clips.size() < StudioProject.MAX_CLIPS - 1) {
            StudioProject.Clip filler = new StudioProject.Clip(UUID.randomUUID().toString(), source.uri, fullName,
                    source.durationMs, source.inMs, source.outMs);
            project.clips.add(filler);
            try { bytes(project); } catch (org.json.JSONException full) { project.clips.remove(project.clips.size() - 1); break; }
        }
        assertTrue("Fixture has room for a bounded metadata filler", project.clips.size() > 4 && project.clips.size() < StudioProject.MAX_CLIPS);
        StudioProject.Clip last = new StudioProject.Clip(UUID.randomUUID().toString(), source.uri, "", source.durationMs, source.inMs, source.outMs);
        project.clips.add(last);
        try { bytes(project); }
        catch (org.json.JSONException full) {
            // Free enough metadata for the final empty record; no media bytes are
            // duplicated because every filler still references the same source.
            project.clips.get(project.clips.size() - 2).name = repeat('\u754c', 256);
        }
        int remaining = ProjectCodec.MAX_BYTES - 1 - bytes(project);
        assertTrue("Remainder fits one valid layer name", remaining >= 0 && remaining <= 1536);
        last.name = repeat('\u754c', remaining / 3)
                + (remaining % 3 == 1 ? "a" : remaining % 3 == 2 ? "\u00e9" : "");
        assertEquals(ProjectCodec.MAX_BYTES - 1, bytes(project));
        assertEquals(1999, project.clips.get(0).animation.points(ClipAnimation.Property.OPACITY).size());
        assertEquals(9999, count(project.clips.get(0).animation));
        // Canonical decode must preserve every valid key, name and source.
        assertEquals(ProjectCodec.encode(project), ProjectCodec.encode(ProjectCodec.decode(ProjectCodec.encode(project))));
        return project;
    }
    private static ClipAnimation keys(StudioProject.ClipSettings settings, boolean oneSlotFree) {
        EnumMap<ClipAnimation.Property, List<ClipAnimation.Keyframe>> tracks = new EnumMap<>(ClipAnimation.Property.class);
        for (int index = 0; index < 5; index++) {
            ClipAnimation.Property property = ClipAnimation.Property.values()[index]; List<ClipAnimation.Keyframe> points = new ArrayList<>();
            int count = oneSlotFree && property == ClipAnimation.Property.OPACITY ? 1999 : 2000;
            for (int time = 0; time < count; time++) points.add(new ClipAnimation.Keyframe(time, property.value(settings), ClipAnimation.Curve.LINEAR));
            tracks.put(property, points);
        }
        return new ClipAnimation(tracks);
    }
    private static int count(ClipAnimation animation) { int count = 0; for (ClipAnimation.Property property : ClipAnimation.Property.values()) count += animation.points(property).size(); return count; }
    private static String repeat(char character, int count) { StringBuilder value = new StringBuilder(count); for (int index = 0; index < count; index++) value.append(character); return value.toString(); }
}
