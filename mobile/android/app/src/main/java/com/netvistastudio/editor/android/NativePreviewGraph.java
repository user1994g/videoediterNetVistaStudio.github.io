package com.netvistastudio.editor.android;

import androidx.media3.common.util.UnstableApi;
import androidx.media3.transformer.Composition;
import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

/**
 * A stable native decoder graph with live per-instance motion and colour matrices.
 * Its player must enable Media3's replayable cache to redraw a paused frame after
 * {@link #updateSettings}. Animated export uses the identical timestamp evaluator.
 */
@UnstableApi
final class NativePreviewGraph {
    private final int width, height;
    private final List<ClipStructure> structure = new ArrayList<>();
    private final List<NativeFrameEffects> effects = new ArrayList<>();
    private final Composition composition;

    NativePreviewGraph(StudioProject snapshot, ProjectFiles files) throws IOException {
        width = snapshot.width; height = snapshot.height;
        composition = MobileExport.composition(snapshot, files, (clip, canvasWidth, canvasHeight, startUs) -> {
            structure.add(new ClipStructure(clip));
            NativeFrameEffects live = new NativeFrameEffects(clip, canvasWidth, canvasHeight, startUs);
            effects.add(live);
            return live.effects(canvasWidth, canvasHeight);
        });
    }

    Composition composition() { return composition; }

    /**
     * Publishes settings by timeline-instance identity, including after Undo replaces
     * model objects. Structural changes require a new graph. No model is retained or
     * mutated, and all matrices are prepared before any live snapshot is replaced.
     */
    boolean updateSettings(StudioProject snapshot) {
        if (snapshot.width != width || snapshot.height != height || snapshot.clips.size() != structure.size()) return false;
        for (int index = 0; index < structure.size(); index++) {
            if (!structure.get(index).matches(snapshot.clips.get(index))) return false;
        }
        List<NativeFrameEffects.Snapshot> prepared = new ArrayList<>(effects.size()); long startUs = 0;
        for (StudioProject.Clip clip : snapshot.clips) {
            prepared.add(new NativeFrameEffects.Snapshot(clip, width, height, startUs));
            startUs = Math.addExact(startUs, Math.multiplyExact(clip.lengthMs(), 1000));
        }
        for (int index = 0; index < effects.size(); index++) effects.get(index).snapshot = prepared.get(index);
        return true;
    }

    private static final class ClipStructure {
        final String id, uri;
        final long durationMs, inMs, outMs;

        ClipStructure(StudioProject.Clip clip) {
            id = clip.id; uri = clip.uri; durationMs = clip.durationMs; inMs = clip.inMs; outMs = clip.outMs;
        }

        boolean matches(StudioProject.Clip clip) {
            return id.equals(clip.id) && uri.equals(clip.uri) && durationMs == clip.durationMs
                    && inMs == clip.inMs && outMs == clip.outMs;
        }
    }

}
