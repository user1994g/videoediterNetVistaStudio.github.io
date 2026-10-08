package com.netvistastudio.editor.android;

import androidx.media3.common.Effect;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.Brightness;
import androidx.media3.effect.Contrast;
import androidx.media3.effect.GlMatrixTransformation;
import androidx.media3.effect.Presentation;
import androidx.media3.effect.RgbMatrix;
import androidx.media3.transformer.Composition;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * A stable native decoder graph with live per-instance motion and colour matrices.
 * Its player must enable Media3's replayable cache to redraw a paused frame after
 * {@link #updateSettings}. Export continues to use MobileExport's fixed effects.
 */
@UnstableApi
final class NativePreviewGraph {
    private final int width, height;
    private final List<ClipStructure> structure = new ArrayList<>();
    private final List<ClipEffects> effects = new ArrayList<>();
    private final Composition composition;

    NativePreviewGraph(StudioProject snapshot, ProjectFiles files) throws IOException {
        width = snapshot.width; height = snapshot.height;
        composition = MobileExport.composition(snapshot, files, (clip, canvasWidth, canvasHeight) -> {
            structure.add(new ClipStructure(clip));
            ClipEffects live = new ClipEffects(clip.settings, canvasWidth, canvasHeight);
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
        List<MatrixSnapshot> prepared = new ArrayList<>(effects.size());
        for (StudioProject.Clip clip : snapshot.clips) prepared.add(new MatrixSnapshot(clip.settings, width, height));
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

    private static final class ClipEffects {
        volatile MatrixSnapshot snapshot;

        ClipEffects(StudioProject.ClipSettings settings, int width, int height) {
            snapshot = new MatrixSnapshot(settings, width, height);
        }

        List<Effect> effects(int width, int height) {
            // These delegates remain in the graph even when initially identity:
            // Media3's default isNoOp is false, so later edits are not optimized away.
            GlMatrixTransformation motion = presentationTimeUs -> snapshot.motion;
            RgbMatrix colour = (presentationTimeUs, useHdr) -> snapshot.rgb;
            return Arrays.asList(Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT),
                    motion, colour);
        }
    }

    private static final class MatrixSnapshot {
        final float[] motion, rgb;

        MatrixSnapshot(StudioProject.ClipSettings settings, int width, int height) {
            if (settings == null) throw new IllegalArgumentException("Clip settings are missing.");
            motion = settings.canvasTransformMatrix(width, height);
            // MobileExport explicitly tone-maps the composition to SDR. Use the
            // SDK's own brightness/contrast matrices, in the fixed export order.
            float[] combined = identity();
            if (settings.brightness != 0f) combined = multiply(new Brightness(settings.brightness).getMatrix(0, false), combined);
            // Contrast(0) is slightly non-identity in the pinned SDK; export omits it.
            if (settings.contrast != 0f) combined = multiply(new Contrast(settings.contrast).getMatrix(0, false), combined);
            if (settings.saturation != 1f) combined = multiply(MobileExport.saturationMatrix(settings.saturation, false), combined);
            if (settings.opacity != 1f) combined = multiply(MobileExport.opacityMatrix(settings.opacity), combined);
            rgb = combined;
        }
    }

    private static float[] identity() {
        return new float[]{1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f};
    }

    /** Column-major product, matching Media3's ordered matrix composition. */
    private static float[] multiply(float[] left, float[] right) {
        float[] result = new float[16];
        for (int column = 0; column < 4; column++) {
            for (int row = 0; row < 4; row++) {
                result[column * 4 + row] = left[row] * right[column * 4]
                        + left[4 + row] * right[column * 4 + 1]
                        + left[8 + row] * right[column * 4 + 2]
                        + left[12 + row] * right[column * 4 + 3];
            }
        }
        return result;
    }
}
