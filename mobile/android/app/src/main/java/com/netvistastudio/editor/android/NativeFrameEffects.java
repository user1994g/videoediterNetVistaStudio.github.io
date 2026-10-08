package com.netvistastudio.editor.android;

import androidx.media3.common.Effect;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.Brightness;
import androidx.media3.effect.Contrast;
import androidx.media3.effect.GlMatrixTransformation;
import androidx.media3.effect.Presentation;
import androidx.media3.effect.RgbMatrix;
import java.util.Arrays;
import java.util.List;

/** Shared frame-timestamp evaluation for the native preview and encoded movie. */
@UnstableApi
final class NativeFrameEffects {
    volatile Snapshot snapshot;
    NativeFrameEffects(StudioProject.Clip clip, int width, int height, long compositionStartUs) {
        snapshot = new Snapshot(clip, width, height, compositionStartUs);
    }
    List<Effect> effects(int width, int height) {
        // Always live, including initially identity: native effect optimization must
        // not remove delegates that a paused-frame redraw will update later.
        GlMatrixTransformation motion = presentationTimeUs -> snapshot.at(presentationTimeUs, false).motion;
        RgbMatrix colour = (presentationTimeUs, useHdr) -> snapshot.at(presentationTimeUs, useHdr).rgb;
        return Arrays.asList(Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT), motion, colour);
    }
    static final class Snapshot {
        private final StudioProject.ClipSettings settings;
        private final ClipAnimation animation;
        private final int width, height;
        private final long inMs, outMs, compositionStartUs;
        private final Matrices staticSdr;
        private long lastTimeUs = Long.MIN_VALUE;
        private boolean lastHdr;
        private Matrices last;
        Snapshot(StudioProject.Clip clip, int width, int height, long compositionStartUs) {
            if (clip.settings == null || clip.animation == null) throw new IllegalArgumentException("Clip effects are missing.");
            clip.animation.validateDuration(clip.durationMs);
            settings = clip.settings.copy(); animation = clip.animation.copy();
            this.width = width; this.height = height; inMs = clip.inMs; outMs = clip.outMs;
            this.compositionStartUs = compositionStartUs;
            staticSdr = new Matrices(settings, width, height, false);
        }
        synchronized Matrices at(long presentationTimeUs, boolean useHdr) {
            // The application's composition explicitly tone-maps to SDR. Do not
            // eagerly ask Brightness for an HDR matrix: the SDK rejects HDR, even
            // when that unused branch would never be drawn by the SDR renderer.
            if (animation.isEmpty() && !useHdr) return staticSdr;
            if (last != null && lastTimeUs == presentationTimeUs && lastHdr == useHdr) return last;
            // Media3 1.11.1 normalizes input frames to composition timestamps before
            // per-item effects. Undo/reorder rebuild offsets; trims retain source keys.
            double sourceMs = inMs + (presentationTimeUs - compositionStartUs) / 1000.0;
            sourceMs = Math.max(inMs, Math.min(outMs, sourceMs));
            last = new Matrices(animation.evaluate(settings, sourceMs), width, height, useHdr);
            lastTimeUs = presentationTimeUs; lastHdr = useHdr; return last;
        }
    }
    static final class Matrices {
        final float[] motion, rgb;
        Matrices(StudioProject.ClipSettings settings, int width, int height, boolean useHdr) {
            motion = settings.canvasTransformMatrix(width, height);
            float[] combined = identity();
            if (settings.brightness != 0f) combined = multiply(new Brightness(settings.brightness).getMatrix(0, useHdr), combined);
            // Contrast(0) is not exactly identity in the pinned SDK. Keep the same
            // neutral omission and effect order as the already-verified static export.
            if (settings.contrast != 0f) combined = multiply(new Contrast(settings.contrast).getMatrix(0, useHdr), combined);
            if (settings.saturation != 1f) combined = multiply(MobileExport.saturationMatrix(settings.saturation, useHdr), combined);
            if (settings.opacity != 1f) combined = multiply(MobileExport.opacityMatrix(settings.opacity), combined);
            rgb = combined;
        }
    }
    private static float[] identity() { return new float[]{1f,0f,0f,0f,0f,1f,0f,0f,0f,0f,1f,0f,0f,0f,0f,1f}; }
    private static float[] multiply(float[] left, float[] right) {
        float[] result = new float[16];
        for (int column = 0; column < 4; column++) for (int row = 0; row < 4; row++) {
            result[column * 4 + row] = left[row] * right[column * 4] + left[4 + row] * right[column * 4 + 1]
                    + left[8 + row] * right[column * 4 + 2] + left[12 + row] * right[column * 4 + 3];
        }
        return result;
    }
}
