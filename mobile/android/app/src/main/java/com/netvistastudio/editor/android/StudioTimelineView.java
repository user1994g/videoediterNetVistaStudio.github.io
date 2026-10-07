package com.netvistastudio.editor.android;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Typeface;
import android.view.GestureDetector;
import android.view.HapticFeedbackConstants;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import java.util.Locale;

/** Native sequential/ripple timeline: actual selection, seek, zoom, pan and drag order. */
public final class StudioTimelineView extends View {
    public interface Listener {
        void selected(int index, long sequencePositionMs);
        void scrubbed(long sequencePositionMs);
        void reordered(int from, int to);
    }
    private static final int BACKGROUND = Color.rgb(24, 27, 33), SEPARATOR = Color.rgb(54, 59, 70);
    private static final int VIDEO = Color.rgb(53, 111, 159), AUDIO = Color.rgb(24, 139, 116), RED = Color.rgb(240, 91, 94);
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path playheadMarker = new Path();
    private final GestureDetector gestures;
    private final ScaleGestureDetector scales;
    private StudioProject project = new StudioProject();
    private Listener listener;
    private int selected = -1, dragged = -1, dropIndex = -1;
    private long playhead;
    private double pixelsPerSecond;
    private double scroll;
    private boolean interactive = true, scrubbing;

    public StudioTimelineView(Context context) {
        super(context); pixelsPerSecond = dp(70);
        setFocusable(true); setContentDescription("Timeline. Tap a clip to select and seek. Drag the ruler to scrub. Swipe to pan, pinch to zoom, and hold a clip to reorder.");
        gestures = new GestureDetector(context, new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(MotionEvent event) { return true; }
            @Override public boolean onSingleTapUp(MotionEvent event) {
                performClick();
                if (!interactive || scrubbing) return true;
                int index = clipAt(event.getX());
                long position = positionAt(event.getX());
                if (index >= 0 && listener != null) listener.selected(index, position);
                else if (listener != null) listener.scrubbed(position);
                return true;
            }
            @Override public void onLongPress(MotionEvent event) {
                if (!interactive || scrubbing || event.getY() < rulerHeight() || scales.isInProgress()) return;
                dragged = clipAt(event.getX()); dropIndex = dragged;
                if (dragged >= 0) { performHapticFeedback(HapticFeedbackConstants.LONG_PRESS); invalidate(); }
            }
            @Override public boolean onScroll(MotionEvent down, MotionEvent current, float distanceX, float distanceY) {
                if (scales.isInProgress() || scrubbing || dragged >= 0) return true;
                scroll = Math.max(0, Math.min(maxScroll(), scroll + distanceX)); invalidate(); return true;
            }
        });
        scales = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScale(ScaleGestureDetector detector) {
                dragged = -1; dropIndex = -1; scrubbing = false;
                zoom(detector.getScaleFactor(), detector.getFocusX()); return true;
            }
        });
    }
    public void setListener(Listener listener) { this.listener = listener; }
    public void setProject(StudioProject project, int selected) {
        this.project = project; this.selected = selected;
        String selection = selected >= 0 && selected < project.clips.size()
                ? " Selected clip " + (selected + 1) + ": " + project.clips.get(selected).name + "." : " No selected clip.";
        setContentDescription("Timeline, " + project.clips.size() + " clips." + selection + " Tap to select and seek; drag the ruler to scrub; swipe to pan; pinch to zoom; hold a clip to reorder. A1 is linked source audio.");
        playhead = Math.min(playhead, project.durationMs()); scroll = Math.min(scroll, maxScroll()); invalidate();
    }
    public void setInteractive(boolean value) { interactive = value; if (!value) { dragged = -1; scrubbing = false; } }
    public void setPlayhead(long value, boolean follow) {
        playhead = Math.max(0, Math.min(value, project.durationMs()));
        if (follow) {
            double x = playhead * pixelsPerSecond / 1000.0 - scroll;
            double visible = Math.max(1, getWidth() - laneHeader());
            if (x > visible - dp(24)) scroll = Math.min(maxScroll(), Math.max(0, x - visible * 0.65 + scroll));
            else if (x < dp(8)) scroll = Math.max(0, playhead * pixelsPerSecond / 1000.0 - dp(16));
        }
        invalidate();
    }
    public void zoomIn() { zoom(1.4, laneHeader() + (getWidth() - laneHeader()) / 2f); }
    public void zoomOut() { zoom(1 / 1.4, laneHeader() + (getWidth() - laneHeader()) / 2f); }
    public void fit() {
        double seconds = Math.max(1, project.durationMs() / 1000.0);
        pixelsPerSecond = Math.max(0.01, (getWidth() - laneHeader() - dp(12)) / seconds); scroll = 0; invalidate();
    }
    private void zoom(double factor, float focusX) {
        double at = (scroll + Math.max(0, focusX - laneHeader())) / pixelsPerSecond;
        pixelsPerSecond = Math.max(0.01, Math.min(dp(700), pixelsPerSecond * factor));
        scroll = Math.max(0, Math.min(maxScroll(), at * pixelsPerSecond - Math.max(0, focusX - laneHeader()))); invalidate();
    }
    @Override public boolean performClick() { super.performClick(); return true; }
    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas); canvas.drawColor(BACKGROUND);
        float header = laneHeader(), ruler = rulerHeight(), lane = laneHeight();
        paint.setTypeface(Typeface.DEFAULT); paint.setTextSize(sp(11)); paint.setColor(Color.rgb(157, 166, 181));
        canvas.drawText("TRACKS", dp(8), dp(20), paint);
        float laneBaseline = Math.min(lane - dp(6), dp(26));
        paint.setTypeface(Typeface.DEFAULT_BOLD); canvas.drawText("V1", dp(10), ruler + laneBaseline, paint);
        canvas.drawText("A1", dp(10), ruler + lane + laneBaseline, paint);
        paint.setTypeface(Typeface.DEFAULT); paint.setTextSize(sp(10));
        if (lane >= dp(48)) {
            canvas.drawText("Picture", dp(10), ruler + dp(43), paint);
            canvas.drawText("Source", dp(10), ruler + lane + dp(43), paint);
        }
        paint.setColor(SEPARATOR); paint.setStrokeWidth(dp(1));
        canvas.drawLine(header, 0, header, getHeight(), paint);
        canvas.drawLine(0, ruler, getWidth(), ruler, paint);
        canvas.drawLine(0, ruler + lane, getWidth(), ruler + lane, paint);
        canvas.drawLine(0, ruler + lane * 2, getWidth(), ruler + lane * 2, paint);
        canvas.save(); canvas.clipRect(header, 0, getWidth(), getHeight());
        drawRuler(canvas, header, ruler);
        long start = 0;
        for (int i = 0; i < project.clips.size(); i++) {
            StudioProject.Clip clip = project.clips.get(i);
            float left = (float) (header + start * pixelsPerSecond / 1000.0 - scroll);
            float right = (float) (left + clip.lengthMs() * pixelsPerSecond / 1000.0);
            if (right >= header && left <= getWidth()) {
                float gap = lane >= dp(48) ? dp(5) : dp(3);
                drawClip(canvas, clip, i, left, Math.max(left + dp(3), right), ruler + gap, lane - gap * 2, VIDEO);
                drawClip(canvas, clip, i, left, Math.max(left + dp(3), right), ruler + lane + gap, lane - gap * 2, AUDIO);
            }
            start += clip.lengthMs();
        }
        if (project.clips.isEmpty()) {
            paint.setTextSize(sp(12)); paint.setColor(Color.rgb(157, 166, 181));
            canvas.drawText("Import sources, then Add to timeline", header + dp(18), ruler + dp(35), paint);
        }
        float cursor = (float) (header + playhead * pixelsPerSecond / 1000.0 - scroll);
        paint.setColor(RED); paint.setStrokeWidth(dp(2)); canvas.drawLine(cursor, 0, cursor, ruler + lane * 2, paint);
        playheadMarker.reset(); playheadMarker.moveTo(cursor - dp(6), 0); playheadMarker.lineTo(cursor + dp(6), 0); playheadMarker.lineTo(cursor, dp(10)); playheadMarker.close(); canvas.drawPath(playheadMarker, paint);
        if (dragged >= 0 && dropIndex >= 0) {
            long dropTime = startOf(dropIndex);
            float dropX = (float) (header + dropTime * pixelsPerSecond / 1000.0 - scroll);
            paint.setColor(Color.WHITE); paint.setStrokeWidth(dp(3)); canvas.drawLine(dropX, ruler, dropX, ruler + lane * 2, paint);
            paint.setTextSize(sp(11)); canvas.drawText("Move clip " + (dragged + 1) + " → " + (dropIndex + 1), Math.max(header + dp(8), Math.min(dropX, getWidth() - dp(150))), getHeight() - dp(8), paint);
        }
        canvas.restore();
    }
    private void drawClip(Canvas canvas, StudioProject.Clip clip, int index, float left, float right, float top, float height, int color) {
        paint.setStyle(Paint.Style.FILL); paint.setColor(color); if (index == dragged) paint.setAlpha(140);
        canvas.drawRoundRect(left + dp(1), top, right - dp(1), top + height, dp(5), dp(5), paint); paint.setAlpha(255);
        if (index == selected) {
            paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(dp(2)); paint.setColor(RED);
            canvas.drawRoundRect(left + dp(1), top, right - dp(1), top + height, dp(5), dp(5), paint); paint.setStyle(Paint.Style.FILL);
        }
        if (right - left > dp(42)) {
            canvas.save(); canvas.clipRect(Math.max(left, laneHeader()), top, right, top + height);
            paint.setTypeface(Typeface.DEFAULT_BOLD); paint.setTextSize(sp(11)); paint.setColor(Color.WHITE);
            float baseline = height < dp(38) ? top + (height - paint.ascent() - paint.descent()) / 2 : top + dp(19);
            canvas.drawText(shortText(clip.name, right - left - dp(12)), left + dp(6), baseline, paint);
            if (height >= dp(38)) {
                paint.setTypeface(Typeface.MONOSPACE); paint.setTextSize(sp(10)); paint.setColor(Color.rgb(226, 233, 240));
                canvas.drawText(String.format(Locale.ROOT, "%.2fs", clip.lengthMs() / 1000.0), left + dp(6), top + dp(37), paint);
            }
            canvas.restore();
        }
    }
    private void drawRuler(Canvas canvas, float header, float ruler) {
        double[] steps = {0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600, 21600, 86400, 604800};
        double step = steps[steps.length - 1];
        for (double candidate : steps) if (candidate * pixelsPerSecond >= dp(72)) { step = candidate; break; }
        double first = Math.floor(scroll / pixelsPerSecond / step) * step;
        double last = (scroll + getWidth() - header) / pixelsPerSecond;
        paint.setTypeface(Typeface.MONOSPACE); paint.setTextSize(sp(10));
        for (double seconds = first; seconds <= last + step; seconds += step) {
            float x = (float) (header + seconds * pixelsPerSecond - scroll);
            paint.setColor(Color.rgb(157, 166, 181)); paint.setStrokeWidth(dp(1));
            canvas.drawLine(x, ruler - dp(8), x, ruler, paint);
            long total = (long) seconds; String label = String.format(Locale.ROOT, "%02d:%02d", total / 60, total % 60);
            canvas.drawText(label, x + dp(4), dp(17), paint);
            paint.setColor(SEPARATOR);
            for (int i = 1; i < 5; i++) { float tick = (float) (x + step * pixelsPerSecond * i / 5); canvas.drawLine(tick, ruler - dp(4), tick, ruler, paint); }
        }
    }
    private String shortText(String text, float width) {
        if (paint.measureText(text) <= width) return text;
        int end = text.length(); while (end > 0 && paint.measureText(text, 0, end) + paint.measureText("…") > width) end--;
        return text.substring(0, end) + "…";
    }
    @Override public boolean onTouchEvent(MotionEvent event) {
        if (!interactive) return false;
        getParent().requestDisallowInterceptTouchEvent(true);
        scales.onTouchEvent(event);
        if (event.getPointerCount() > 1 || scales.isInProgress()) { scrubbing = false; dragged = -1; gestures.onTouchEvent(event); return true; }
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
            // The compact drawn ruler keeps a 44dp scrub hit area; the clip's
            // linked picture/audio blocks share the remaining selection area.
            scrubbing = event.getY() < Math.max(dp(44), rulerHeight()) && event.getX() >= laneHeader();
            if (scrubbing && listener != null) listener.scrubbed(positionAt(event.getX()));
        } else if (event.getActionMasked() == MotionEvent.ACTION_MOVE) {
            if (scrubbing && listener != null) listener.scrubbed(positionAt(event.getX()));
            if (dragged >= 0) {
                dropIndex = Math.max(0, clipAt(event.getX()));
                if (event.getX() < laneHeader() + dp(22)) scroll = Math.max(0, scroll - dp(10));
                if (event.getX() > getWidth() - dp(22)) scroll = Math.min(maxScroll(), scroll + dp(10));
                invalidate();
            }
        }
        gestures.onTouchEvent(event);
        if (event.getActionMasked() == MotionEvent.ACTION_UP || event.getActionMasked() == MotionEvent.ACTION_CANCEL) {
            if (event.getActionMasked() == MotionEvent.ACTION_UP && dragged >= 0 && dropIndex >= 0 && dragged != dropIndex && listener != null) listener.reordered(dragged, dropIndex);
            dragged = -1; dropIndex = -1; scrubbing = false; invalidate();
            getParent().requestDisallowInterceptTouchEvent(false);
        }
        return true;
    }
    private long positionAt(float x) { return Math.max(0, Math.min(project.durationMs(), Math.round((scroll + Math.max(0, x - laneHeader())) * 1000 / pixelsPerSecond))); }
    private int clipAt(float x) {
        if (project.clips.isEmpty() || x < laneHeader()) return -1;
        long position = positionAt(x), start = 0;
        for (int i = 0; i < project.clips.size(); i++) { start += project.clips.get(i).lengthMs(); if (position < start) return i; }
        return project.clips.size() - 1;
    }
    private long startOf(int index) { long value = 0; for (int i = 0; i < index; i++) value += project.clips.get(i).lengthMs(); return value; }
    private double maxScroll() { return Math.max(0, project.durationMs() * pixelsPerSecond / 1000.0 - Math.max(1, getWidth() - laneHeader()) + dp(24)); }
    private float laneHeader() { return dp(66); }
    private float rulerHeight() { return dp(32); }
    private float laneHeight() { return Math.min(dp(62), Math.max(dp(20), (getHeight() - rulerHeight() - dp(4)) / 2)); }
    private float dp(float value) { return value * getResources().getDisplayMetrics().density; }
    private float sp(float value) { return value * getResources().getDisplayMetrics().scaledDensity; }
}
