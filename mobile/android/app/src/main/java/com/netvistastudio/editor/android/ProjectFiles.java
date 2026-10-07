package com.netvistastudio.editor.android;

import android.content.Context;
import android.net.Uri;
import android.util.AtomicFile;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.List;
import java.util.UUID;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;
import java.util.zip.ZipOutputStream;

/** Self-contained mobile projects; never extracts arbitrary archive paths. */
public final class ProjectFiles {
    public static final long MAX_VIDEO_BYTES = 4L * 1024 * 1024 * 1024;
    public static final long MAX_PROJECT_BYTES = 12L * 1024 * 1024 * 1024;
    private final Context context;
    private final File media;
    private final AtomicFile draft;

    public ProjectFiles(Context context) throws IOException {
        this.context = context.getApplicationContext();
        media = new File(context.getFilesDir(), "mobile-media");
        if (!media.isDirectory() && !media.mkdirs()) throw new IOException("App storage is unavailable.");
        draft = new AtomicFile(new File(context.getFilesDir(), "mobile-draft.json"));
    }

    public File mediaFile(StudioProject.Clip clip) throws IOException {
        if (!StudioProject.validMediaPath(clip.id, clip.uri)) throw new IOException("Invalid media identifier.");
        return new File(media, clip.sourceId() + ".video");
    }

    public File importVideo(Uri uri, String id) throws IOException {
        if (!StudioProject.validMediaPath(id, "media/" + id + ".video")) throw new IOException("Invalid media identifier.");
        File target = new File(media, id + ".video");
        if (target.exists()) throw new IOException("Media identifier already exists.");
        try (InputStream input = context.getContentResolver().openInputStream(uri); OutputStream output = new FileOutputStream(target)) {
            if (input == null) throw new IOException("Selected video cannot be read.");
            copy(input, output, MAX_VIDEO_BYTES);
            return target;
        } catch (IOException e) { target.delete(); throw e; }
    }

    public synchronized void saveDraft(StudioProject project) throws Exception {
        FileOutputStream output = null;
        try {
            output = draft.startWrite();
            output.write(ProjectCodec.encode(project).getBytes(StandardCharsets.UTF_8));
            draft.finishWrite(output);
        } catch (Exception e) { if (output != null) draft.failWrite(output); throw e; }
    }

    public synchronized StudioProject loadDraft() throws Exception {
        if (!draft.getBaseFile().exists()) return new StudioProject();
        try (InputStream input = draft.openRead()) { return ProjectCodec.decode(readText(input)); }
    }

    public void saveArchive(StudioProject project, OutputStream output) throws Exception {
        List<StudioProject.Clip> sources = project.sources();
        long total = 0;
        for (StudioProject.Clip clip : sources) {
            File source = mediaFile(clip);
            if (!source.isFile() || source.length() < 1 || source.length() > MAX_VIDEO_BYTES) throw new IOException("A source video is missing or too large.");
            total = Math.addExact(total, source.length());
            if (total > MAX_PROJECT_BYTES) throw new IOException("This beta supports projects up to 12 GiB.");
        }
        try (ZipOutputStream zip = new ZipOutputStream(output)) {
            // Video containers are already compressed. Avoid battery-heavy recompression.
            zip.setLevel(0);
            zip.putNextEntry(new ZipEntry("project.json"));
            zip.write(ProjectCodec.encode(project).getBytes(StandardCharsets.UTF_8)); zip.closeEntry();
            for (StudioProject.Clip clip : sources) {
                zip.putNextEntry(new ZipEntry(clip.uri));
                try (InputStream input = new FileInputStream(mediaFile(clip))) { copy(input, zip, MAX_VIDEO_BYTES); }
                zip.closeEntry();
            }
        }
    }

    public StudioProject loadArchive(InputStream input) throws Exception {
        File staging = new File(context.getCacheDir(), "project-import-" + UUID.randomUUID());
        if (!staging.mkdir()) throw new IOException("Import staging is unavailable.");
        Map<String, File> assets = new HashMap<>(); Set<String> names = new HashSet<>();
        java.util.List<File> installed = new java.util.ArrayList<>();
        String manifest = null; long total = 0;
        try {
            try (ZipInputStream zip = new ZipInputStream(input)) {
                ZipEntry entry;
                while ((entry = zip.getNextEntry()) != null) {
                    String name = entry.getName();
                    if (!names.add(name) || entry.isDirectory() || names.size() > StudioProject.MAX_ASSETS + 1) throw new IOException("Duplicate or invalid project entry.");
                    if ("project.json".equals(name)) { manifest = readText(zip); total += manifest.getBytes(StandardCharsets.UTF_8).length; }
                    else {
                        if (!name.matches("media/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.video")) throw new IOException("Unsafe project media path.");
                        File target = new File(staging, UUID.randomUUID() + ".video");
                        try (OutputStream out = new FileOutputStream(target)) {
                            long size = copy(zip, out, Math.min(MAX_VIDEO_BYTES, MAX_PROJECT_BYTES - total));
                            if (size == 0) throw new IOException("Empty video in project."); total += size;
                        }
                        assets.put(name, target);
                    }
                    if (total > MAX_PROJECT_BYTES) throw new IOException("Project exceeds the 12 GiB beta limit.");
                    zip.closeEntry();
                }
            }
            if (manifest == null) throw new IOException("Project manifest is missing.");
            StudioProject decoded = ProjectCodec.decode(manifest);
            List<StudioProject.Clip> decodedSources = decoded.sources();
            if (assets.size() != decodedSources.size()) throw new IOException("Project media does not match its manifest.");
            StudioProject result = new StudioProject();
            result.title = decoded.title; result.width = decoded.width; result.height = decoded.height;
            Map<String, String> remappedSources = new HashMap<>();
            for (StudioProject.Clip clip : decodedSources) {
                File source = assets.get(clip.uri);
                if (source == null) throw new IOException("Project is missing " + clip.name);
                String id = UUID.randomUUID().toString(); File destination = new File(media, id + ".video");
                if (destination.exists() || !source.renameTo(destination)) throw new IOException("Cannot install project media.");
                installed.add(destination);
                String path = "media/" + id + ".video"; remappedSources.put(clip.uri, path);
                result.assets.add(new StudioProject.Clip(id, path, clip.name, clip.durationMs, 0, clip.durationMs));
            }
            for (StudioProject.Clip clip : decoded.clips) {
                String path = remappedSources.get(clip.uri);
                if (path == null) throw new IOException("Missing timeline source.");
                result.clips.add(new StudioProject.Clip(UUID.randomUUID().toString(), path, clip.name, clip.durationMs,
                        clip.inMs, clip.outMs, clip.settings.copy()));
            }
            return result;
        } catch (Exception failure) {
            for (File file : installed) file.delete();
            throw failure;
        } finally {
            File[] temporary = staging.listFiles(); if (temporary != null) for (File file : temporary) file.delete();
            staging.delete();
        }
    }

    public static long copy(InputStream input, OutputStream output, long limit) throws IOException {
        byte[] buffer = new byte[256 * 1024]; int count; long total = 0;
        while ((count = input.read(buffer)) != -1) {
            total += count;
            if (total > limit) throw new IOException("Media exceeds the beta storage limit.");
            output.write(buffer, 0, count);
        }
        return total;
    }
    private static String readText(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream(); copy(input, output, ProjectCodec.MAX_BYTES);
        return output.toString(StandardCharsets.UTF_8.name());
    }
}
