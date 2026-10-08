package com.netvistastudio.editor.android;

import android.content.Context;
import android.net.Uri;
import androidx.media3.common.C;
import androidx.media3.common.Effect;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.Presentation;
import androidx.media3.effect.Brightness;
import androidx.media3.effect.Contrast;
import androidx.media3.effect.GlMatrixTransformation;
import androidx.media3.effect.RgbMatrix;
import androidx.media3.transformer.Composition;
import androidx.media3.transformer.EditedMediaItem;
import androidx.media3.transformer.EditedMediaItemSequence;
import androidx.media3.transformer.Effects;
import androidx.media3.transformer.Transformer;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;

@UnstableApi
public final class MobileExport {
    private MobileExport() {}

    /**
     * Shared per-clip pipeline for CompositionPlayer preview and Transformer export. Source
     * fitting precedes user transforms; transforms retain the selected canvas and clip at its
     * edges. Colour uses the native Media3 working space shared by both paths. The verified
     * default SDR pipeline applies saturation to encoded BT.709 RGB; it is not yet a claim
     * of linear-light colour parity with the Mac renderer. This single-track editor flattens
     * opacity onto black, because the opaque H.264 output cannot store an alpha channel.
     */
    public static List<Effect> videoEffects(StudioProject.Clip clip, int width, int height) {
        return videoEffects(clip, width, height, 0);
    }

    static List<Effect> videoEffects(StudioProject.Clip clip, int width, int height, long compositionStartUs) {
        if (clip == null || clip.settings == null) throw new IllegalArgumentException("Clip settings are missing.");
        if (!clip.animation.isEmpty()) return Collections.unmodifiableList(new NativeFrameEffects(clip, width, height, compositionStartUs).effects(width, height));
        StudioProject.ClipSettings settings = clip.settings.copy();
        List<Effect> effects = new ArrayList<>();
        effects.add(Presentation.createForWidthAndHeight(width, height, Presentation.LAYOUT_SCALE_TO_FIT));
        if (settings.scale != 1f || settings.rotationDegrees != 0f
                || settings.positionX != 0f || settings.positionY != 0f) {
            float[] matrix = settings.canvasTransformMatrix(width, height);
            effects.add((GlMatrixTransformation) presentationTimeUs -> matrix);
        }
        if (settings.brightness != 0f) effects.add(new Brightness(settings.brightness));
        if (settings.contrast != 0f) effects.add(new Contrast(settings.contrast));
        if (settings.saturation != 1f) {
            float[] sdrMatrix = saturationMatrix(settings.saturation, false);
            float[] hdrMatrix = saturationMatrix(settings.saturation, true);
            effects.add((RgbMatrix) (presentationTimeUs, useHdr) -> useHdr ? hdrMatrix : sdrMatrix);
        }
        if (settings.opacity != 1f) {
            // Merely adding AlphaScale would leave RGB unchanged when H.264 discards alpha.
            // RGB * opacity is exactly a one-layer fade over our opaque black background.
            float[] matrix = opacityMatrix(settings.opacity);
            effects.add((RgbMatrix) (presentationTimeUs, useHdr) -> matrix);
        }
        return Collections.unmodifiableList(effects);
    }

    static float[] saturationMatrix(float saturation, boolean useHdr) {
        // Luminance coefficients match the colour primaries supplied by RgbMatrix's contract.
        float red = useHdr ? 0.2627f : 0.2126f;
        float green = useHdr ? 0.6780f : 0.7152f;
        float blue = useHdr ? 0.0593f : 0.0722f;
        float inverse = 1f - saturation;
        return new float[]{
                red * inverse + saturation, red * inverse, red * inverse, 0f,
                green * inverse, green * inverse + saturation, green * inverse, 0f,
                blue * inverse, blue * inverse, blue * inverse + saturation, 0f,
                0f, 0f, 0f, 1f
        };
    }

    static float[] opacityMatrix(float opacity) {
        return new float[]{opacity, 0f, 0f, 0f, 0f, opacity, 0f, 0f,
                0f, 0f, opacity, 0f, 0f, 0f, 0f, 1f};
    }

    /** Exactly the same clip order and time boundaries are used by preview and export. */
    public static List<MediaItem> previewItems(StudioProject project, ProjectFiles files) throws IOException {
        List<MediaItem> result = new ArrayList<>();
        for (StudioProject.Clip clip : project.clips) {
            java.io.File source = files.mediaFile(clip);
            if (!source.isFile()) throw new IOException("Source video is missing: " + clip.name);
            result.add(new MediaItem.Builder().setUri(Uri.fromFile(source)).setMediaId(clip.id)
                    .setClippingConfiguration(new MediaItem.ClippingConfiguration.Builder()
                            .setStartPositionMs(clip.inMs).setEndPositionMs(clip.outMs).build()).build());
        }
        return result;
    }

    public static Composition composition(StudioProject project, ProjectFiles files) throws IOException {
        return composition(project, files, MobileExport::videoEffects);
    }

    /** Preview may bind live matrices without changing source, trim or audio composition. */
    interface EffectsFactory {
        List<Effect> create(StudioProject.Clip clip, int width, int height, long compositionStartUs);
    }

    static Composition composition(StudioProject project, ProjectFiles files, EffectsFactory effectsFactory) throws IOException {
        if (project.clips.isEmpty()) throw new IOException("Import a video before exporting.");
        List<EditedMediaItem> edited = new ArrayList<>();
        List<MediaItem> items = previewItems(project, files);
        long compositionStartUs = 0;
        for (int i = 0; i < items.size(); i++) {
            MediaItem item = items.get(i);
            StudioProject.Clip clip = project.clips.get(i);
            edited.add(new EditedMediaItem.Builder(item).setFrameRate(30)
                    // CompositionPlayer needs source duration BEFORE clipping, not edit length.
                    .setDurationUs(Math.multiplyExact(clip.durationMs, 1000))
                    .setEffects(new Effects(Collections.emptyList(), effectsFactory.create(clip, project.width, project.height, compositionStartUs)))
                    .build());
            compositionStartUs = Math.addExact(compositionStartUs, Math.multiplyExact(clip.lengthMs(), 1000));
        }
        // Explicit audio/video track types synthesize silence for silent clips and
        // preserve continuous audio across mixed sources. Geometry is normalized
        // per item, so portrait/landscape source dimensions may differ safely.
        EditedMediaItemSequence sequence = new EditedMediaItemSequence.Builder(
                new HashSet<>(Arrays.asList(C.TRACK_TYPE_AUDIO, C.TRACK_TYPE_VIDEO)))
                .addItems(edited).build();
        return new Composition.Builder(sequence).setTransmuxAudio(false).setTransmuxVideo(false)
                .setHdrMode(Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL).build();
    }

    public static Transformer transformer(Context context, Transformer.Listener listener) {
        return new Transformer.Builder(context).setVideoMimeType(MimeTypes.VIDEO_H264)
                .setAudioMimeType(MimeTypes.AUDIO_AAC).addListener(listener).build();
    }
}
