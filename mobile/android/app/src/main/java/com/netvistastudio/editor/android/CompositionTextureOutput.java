package com.netvistastudio.editor.android;

import android.graphics.SurfaceTexture;
import android.os.Looper;
import android.view.Surface;
import android.view.TextureView;
import androidx.media3.common.ForwardingPlayer;
import androidx.media3.common.util.Size;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.transformer.CompositionPlayer;

/**
 * Display-only adapter for Media3 1.11.1's CompositionPlayer. That version's
 * Player.setVideoTextureView() throws: its supported arbitrary-Surface API is
 * specifically setVideoSurface(Surface, Size). Keep all playback, timelines,
 * effects, listeners and exports on the original engine and adapt only output.
 *
 * A TextureView is composed inside the same window render as editor chrome.
 * Removing its view cannot leave a separate SurfaceView underlay showing an
 * old clip after the newly empty window has committed its display frame.
 */
@UnstableApi
final class CompositionTextureOutput extends ForwardingPlayer implements TextureView.SurfaceTextureListener {
    private final CompositionPlayer engine;
    // Nullable references intentionally use plain Java here. The platform's
    // android.annotation.Nullable is hidden from third-party applications.
    private TextureView view;
    private SurfaceTexture texture;
    private Surface surface;
    private Size outputSize = Size.ZERO;
    private int createdSurfaces, releasedSurfaces;

    CompositionTextureOutput(CompositionPlayer engine) { super(engine); this.engine = engine; }
    CompositionPlayer engine() { return engine; }
    TextureView boundView() { return view; }
    Surface ownedSurface() { return surface; }
    int createdSurfaceCount() { return createdSurfaces; }
    int releasedSurfaceCount() { return releasedSurfaces; }

    private void verifyThread() {
        if (Looper.myLooper() != engine.getApplicationLooper()) {
            throw new IllegalStateException("Bind native monitor output on the composition player's application thread.");
        }
    }

    @Override public void setVideoTextureView(TextureView next) {
        verifyThread();
        if (view == next) return;
        detach();
        if (next == null) return;
        if (next.getSurfaceTextureListener() != null && next.getSurfaceTextureListener() != this) {
            throw new IllegalStateException("The program monitor TextureView already has an output owner.");
        }
        view = next; next.setSurfaceTextureListener(this);
        if (next.isAvailable() && next.getSurfaceTexture() != null) {
            attach(next.getSurfaceTexture(), next.getWidth(), next.getHeight());
        }
    }

    @Override public void clearVideoTextureView(TextureView obsolete) {
        verifyThread();
        // A late detach from an obsolete PlayerView must not clear a newer view.
        if (obsolete == view) detach();
    }

    private void attach(SurfaceTexture current, int width, int height) {
        verifyThread();
        if (view == null || view.getSurfaceTexture() != current) return;
        if (texture != current) { clearOwnedSurface(); texture = current; }
        if (width <= 0 || height <= 0) return;
        if (surface == null) { surface = new Surface(current); createdSurfaces++; }
        outputSize = new Size(width, height);
        // Explicit dimensions are required by CompositionPlayer, and change
        // with rotation, panel layout, aspect-fit resizing and window changes.
        engine.setVideoSurface(surface, outputSize);
    }

    private void clearOwnedSurface() {
        verifyThread();
        Surface obsolete = surface;
        if (obsolete != null) {
            // Pinned CompositionPlayer checks identity against its direct
            // Surface output; clearVideoSurface(null) would throw. This exact
            // overload blocks until the video graph stops using this Surface.
            // Never release its producer handle before that synchronous clear.
            engine.clearVideoSurface(obsolete);
            obsolete.release(); releasedSurfaces++; surface = null;
        }
        texture = null; outputSize = Size.ZERO;
    }

    private void detach() {
        TextureView obsolete = view;
        if (obsolete != null && obsolete.getSurfaceTextureListener() == this) obsolete.setSurfaceTextureListener(null);
        clearOwnedSurface(); view = null;
        // TextureView/the framework owns SurfaceTexture and releases it when
        // its view is detached; only our new Surface wrapper is ours to free.
    }

    @Override public void onSurfaceTextureAvailable(SurfaceTexture current, int width, int height) { attach(current, width, height); }
    @Override public void onSurfaceTextureSizeChanged(SurfaceTexture current, int width, int height) {
        if (current == texture || (view != null && view.getSurfaceTexture() == current)) attach(current, width, height);
    }
    @Override public boolean onSurfaceTextureDestroyed(SurfaceTexture obsolete) {
        verifyThread();
        if (obsolete == texture) clearOwnedSurface();
        return true; // The TextureView still owns and releases SurfaceTexture.
    }
    @Override public void onSurfaceTextureUpdated(SurfaceTexture current) { /* Native window rendering owns presentation. */ }
    @Override public Size getSurfaceSize() { return outputSize; }
    @Override public void release() { verifyThread(); detach(); super.release(); }
}
