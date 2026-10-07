package com.netvistastudio.editor.android;

import android.content.Context;
import android.net.Uri;
import androidx.media3.common.C;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.effect.Presentation;
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
        if (project.clips.isEmpty()) throw new IOException("Import a video before exporting.");
        List<EditedMediaItem> edited = new ArrayList<>();
        for (MediaItem item : previewItems(project, files)) {
            edited.add(new EditedMediaItem.Builder(item).setFrameRate(30)
                    .setEffects(new Effects(Collections.emptyList(), Collections.singletonList(
                            Presentation.createForWidthAndHeight(project.width, project.height, Presentation.LAYOUT_SCALE_TO_FIT))))
                    .build());
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
