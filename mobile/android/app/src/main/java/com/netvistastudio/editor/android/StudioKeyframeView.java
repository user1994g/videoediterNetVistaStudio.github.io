package com.netvistastudio.editor.android;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.view.MotionEvent;
import android.view.View;

/** Native drawn clip-local animation ruler; tapping a diamond seeks to its exact time. */
final class StudioKeyframeView extends View {
    interface Listener { void seekSource(long sourceMs); }
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path diamond = new Path();
    private final float density;
    private StudioProject.Clip clip;
    private ClipAnimation.Property property = ClipAnimation.Property.OPACITY;
    private long sourceMs;
    private Listener listener;
    StudioKeyframeView(Context context) {
        super(context); density = getResources().getDisplayMetrics().density;
        setMinimumHeight(dp(90)); setContentDescription("Animation keyframe timeline. Drag to seek, or tap a diamond.");
        setFocusable(true);
    }
    void setListener(Listener listener) { this.listener = listener; }
    void setClip(StudioProject.Clip clip, ClipAnimation.Property property, long sourceMs) {
        this.clip = clip; this.property = property; this.sourceMs = sourceMs; invalidate();
    }
    void setSourcePosition(long sourceMs) { this.sourceMs = sourceMs; invalidate(); }
    private int dp(float value) { return Math.round(value * density); }
    private float x(long time) { return dp(14) + (getWidth() - dp(28)) * (float) (time - clip.inMs) / Math.max(1, clip.lengthMs()); }
    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas); canvas.drawColor(Color.rgb(24, 27, 33)); if (clip == null) return;
        paint.setTextSize(dp(10)); paint.setColor(Color.rgb(157, 166, 181));
        canvas.drawText("0:00", dp(12), dp(16), paint);
        String end = String.format(java.util.Locale.US, "%.2fs", clip.lengthMs() / 1000.0);
        canvas.drawText(end, getWidth() - dp(12) - paint.measureText(end), dp(16), paint);
        float y = dp(48); paint.setStrokeWidth(dp(1)); paint.setColor(Color.rgb(54, 59, 70));
        canvas.drawLine(dp(14), y, getWidth() - dp(14), y, paint);
        for (ClipAnimation.Keyframe point : clip.animation.points(property)) {
            if (point.sourceMs < clip.inMs || point.sourceMs > clip.outMs) continue;
            float x = x(point.sourceMs), radius = dp(6);
            diamond.reset(); diamond.moveTo(x, y - radius); diamond.lineTo(x + radius, y);
            diamond.lineTo(x, y + radius); diamond.lineTo(x - radius, y); diamond.close();
            paint.setColor(point.sourceMs == sourceMs ? Color.WHITE : Color.rgb(78, 165, 226)); canvas.drawPath(diamond, paint);
        }
        float head = x(Math.max(clip.inMs, Math.min(clip.outMs, sourceMs)));
        paint.setColor(Color.rgb(240, 91, 94)); paint.setStrokeWidth(dp(2)); canvas.drawLine(head, dp(23), head, dp(69), paint);
        paint.setTextSize(dp(10)); paint.setColor(Color.rgb(157, 166, 181));
        canvas.drawText(clip.animation.points(property).isEmpty() ? "No keys · Add one at the playhead" : "Diamonds seek · keys stay with source time", dp(12), dp(84), paint);
    }
    @Override public boolean onTouchEvent(MotionEvent event) {
        if (!isEnabled() || clip == null || listener == null) return false;
        if (event.getActionMasked() == MotionEvent.ACTION_DOWN || event.getActionMasked() == MotionEvent.ACTION_MOVE || event.getActionMasked() == MotionEvent.ACTION_UP) {
            getParent().requestDisallowInterceptTouchEvent(event.getActionMasked() != MotionEvent.ACTION_UP);
            double fraction = Math.max(0, Math.min(1, (event.getX() - dp(14)) / Math.max(1, getWidth() - dp(28))));
            long source = clip.inMs + Math.round(fraction * clip.lengthMs());
            if (event.getActionMasked() == MotionEvent.ACTION_UP) {
                float nearest = dp(22); // 44dp target width around each visible diamond.
                for (ClipAnimation.Keyframe point : clip.animation.points(property)) {
                    if (point.sourceMs < clip.inMs || point.sourceMs > clip.outMs) continue;
                    float distance = Math.abs(event.getX() - x(point.sourceMs));
                    if (distance < nearest) { nearest = distance; source = point.sourceMs; }
                }
                performClick();
            }
            listener.seekSource(source); return true;
        }
        if (event.getActionMasked() == MotionEvent.ACTION_CANCEL) { getParent().requestDisallowInterceptTouchEvent(false); return true; }
        return false;
    }
    @Override public boolean performClick() { super.performClick(); return true; }
}
