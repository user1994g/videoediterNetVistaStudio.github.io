package com.netvistastudio.editor.android;

import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.view.MotionEvent;
import android.view.ScaleGestureDetector;
import android.view.View;
import java.util.ArrayList;
import java.util.List;

/** Native photo surface. View zoom is independent of the saved layer transform. */
public final class PhotoCanvasView extends View {
    public interface Listener {
        void select(String id);
        void moveStarted(String id);
        void moveChanged(String id, double x, double y);
        void moveFinished(boolean cancelled);
        void stroke(String id, List<float[]> documentPoints, boolean erase);
        void zoomChanged(float value);
    }
    public enum Tool { MOVE, HAND, BRUSH, ERASER }
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
    private final ScaleGestureDetector scaleDetector;
    private final List<float[]> points = new ArrayList<>();
    private PhotoDocument document;
    private Bitmap image;
    private Listener listener;
    private Tool tool = Tool.MOVE;
    private float zoom = 1, panX, panY, downX, downY, lastX, lastY;
    private double originalX, originalY;
    private boolean moving, drawing, navigating, enabled = true;
    private String gestureId;
    public PhotoCanvasView(Context context) {
        super(context); setBackgroundColor(Color.rgb(18,20,24)); setContentDescription("Photo canvas. Pinch to zoom; use Hand or two fingers to pan.");
        scaleDetector = new ScaleGestureDetector(context, new ScaleGestureDetector.SimpleOnScaleGestureListener() {
            @Override public boolean onScaleBegin(ScaleGestureDetector detector) { cancelEdit(); navigating = true; return true; }
            @Override public boolean onScale(ScaleGestureDetector detector) {
                float old = zoom; zoom = Math.max(.05f, Math.min(32, zoom * detector.getScaleFactor()));
                float cx = getWidth()/2f, cy = getHeight()/2f, ratio = zoom / old;
                panX = detector.getFocusX() - cx - (detector.getFocusX() - cx - panX) * ratio;
                panY = detector.getFocusY() - cy - (detector.getFocusY() - cy - panY) * ratio;
                invalidate(); announceZoom(); return true;
            }
        });
    }
    public void setListener(Listener value) { listener = value; }
    public void setEditingEnabled(boolean value) { enabled = value; if (!value) cancelEdit(); }
    public void setTool(Tool value) { cancelEdit(); tool = value; }
    public Tool tool() { return tool; }
    public void setDocument(PhotoDocument value) { document = value; invalidate(); }
    /** Caller retains/recycles the bitmap after replacing it on the UI thread. */
    public void setImage(Bitmap value) { image = value; invalidate(); }
    public Bitmap displayedImage() { return image; }
    public void fit() { cancelEdit(); zoom = 1; panX = panY = 0; invalidate(); announceZoom(); }
    public void zoomBy(float factor) { zoom = Math.max(.05f, Math.min(32, zoom * factor)); invalidate(); announceZoom(); }
    private void announceZoom() { if (listener != null) listener.zoomChanged(zoom); }
    private float fitScale() { return document == null ? 1 : Math.max(.00001f, Math.min(Math.max(1,getWidth()-48)/(float)document.width, Math.max(1,getHeight()-48)/(float)document.height)); }
    public float displayScale() { return fitScale() * zoom; }
    public float[] documentPoint(float x, float y) {
        if (document == null) return new float[]{0,0}; float s = displayScale();
        return new float[]{(x-getWidth()/2f-panX)/s+document.width/2f, document.height/2f-(y-getHeight()/2f-panY)/s};
    }
    private float screenX(double x) { return getWidth()/2f+panX+(float)(x-document.width/2.0)*displayScale(); }
    private float screenY(double y) { return getHeight()/2f+panY-(float)(y-document.height/2.0)*displayScale(); }
    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas); if (document == null) return;
        RectF frame = new RectF(screenX(0), screenY(document.height), screenX(document.width), screenY(0));
        canvas.save(); canvas.clipRect(frame); int tile = Math.max(8,Math.round(12*getResources().getDisplayMetrics().density));
        int left = Math.max(0,(int)frame.left), top = Math.max(0,(int)frame.top), right = Math.min(getWidth(),(int)frame.right+1), bottom = Math.min(getHeight(),(int)frame.bottom+1);
        for (int y=top/tile*tile;y<bottom;y+=tile) for(int x=left/tile*tile;x<right;x+=tile) { paint.setColor(((x/tile+y/tile)&1)==0?0xffaaaaaa:0xff777777); canvas.drawRect(x,y,x+tile,y+tile,paint); }
        paint.setColor(Color.WHITE); if (image != null && !image.isRecycled()) canvas.drawBitmap(image,null,frame,paint);
        if (drawing && points.size()>1) { Path path = new Path(); path.moveTo(screenX(points.get(0)[0]),screenY(points.get(0)[1])); for(int i=1;i<points.size();i++)path.lineTo(screenX(points.get(i)[0]),screenY(points.get(i)[1])); paint.setStyle(Paint.Style.STROKE); paint.setStrokeWidth(2*getResources().getDisplayMetrics().density); paint.setColor(Color.CYAN); canvas.drawPath(path,paint); paint.setStyle(Paint.Style.FILL); }
        canvas.restore();
        PhotoDocument.Layer layer = document.layer(document.selectedLayerId);
        if (layer != null && !layer.group && !layer.adjustment && tool==Tool.MOVE) {
            Path bounds = new Path(); double[][] corners={{0,0},{layer.pixels.width,0},{layer.pixels.width,layer.pixels.height},{0,layer.pixels.height}};
            for(int i=0;i<corners.length;i++){double[] p=layer.documentPoint(corners[i][0],corners[i][1],document.width,document.height); if(i==0)bounds.moveTo(screenX(p[0]),screenY(p[1]));else bounds.lineTo(screenX(p[0]),screenY(p[1]));} bounds.close();
            paint.setColor(0xff59b3ff);paint.setStyle(Paint.Style.STROKE);paint.setStrokeWidth(2);canvas.drawPath(bounds,paint);paint.setStyle(Paint.Style.FILL);
        }
    }
    @Override public boolean onTouchEvent(MotionEvent event) {
        if(document==null)return false;
        scaleDetector.onTouchEvent(event); int action=event.getActionMasked();
        if(action==MotionEvent.ACTION_POINTER_DOWN){cancelEdit();navigating=true;lastX=event.getX();lastY=event.getY();return true;}
        if(action==MotionEvent.ACTION_DOWN){downX=lastX=event.getX();downY=lastY=event.getY();navigating=tool==Tool.HAND;gestureId=null;
            if(navigating||!enabled)return true;
            float[] p=documentPoint(downX,downY);
            if(tool==Tool.MOVE){String id=hit(p[0],p[1]);if(id!=null&&listener!=null){listener.select(id);PhotoDocument.Layer layer=document.layer(id);if(layer!=null&&!layer.group&&!layer.adjustment&&!layer.locked){gestureId=id;originalX=layer.positionX;originalY=layer.positionY;listener.moveStarted(id);moving=true;}}}
            else{PhotoDocument.Layer layer=document.layer(document.selectedLayerId);if(layer!=null&&!layer.group&&!layer.adjustment&&!layer.locked){gestureId=layer.id;points.clear();points.add(p);drawing=true;}}
            getParent().requestDisallowInterceptTouchEvent(true);return true;}
        if(action==MotionEvent.ACTION_MOVE){if(scaleDetector.isInProgress())return true;
            if(navigating){panX+=event.getX()-lastX;panY+=event.getY()-lastY;invalidate();}
            else if(moving&&listener!=null)listener.moveChanged(gestureId,originalX+(event.getX()-downX)/displayScale(),originalY-(event.getY()-downY)/displayScale());
            else if(drawing&&points.size()<20000){points.add(documentPoint(event.getX(),event.getY()));invalidate();}
            lastX=event.getX();lastY=event.getY();return true;}
        if(action==MotionEvent.ACTION_UP){if(moving&&listener!=null)listener.moveFinished(false);if(drawing&&listener!=null)listener.stroke(gestureId,new ArrayList<>(points),tool==Tool.ERASER);moving=drawing=navigating=false;points.clear();invalidate();performClick();return true;}
        if(action==MotionEvent.ACTION_CANCEL){cancelEdit();return true;}return true;
    }
    private String hit(float x,float y){for(PhotoDocument.Layer layer:document.layers){PhotoDocument.Layer parent=document.layer(layer.groupId);if(!layer.visible||layer.group||layer.adjustment||parent!=null&&!parent.visible)continue;double[]p=layer.sourcePoint(x,y,document.width,document.height);if(p[0]>=0&&p[1]>=0&&p[0]<layer.pixels.width&&p[1]<layer.pixels.height)return layer.id;}return null;}
    private void cancelEdit(){boolean wasMoving=moving;moving=drawing=false;gestureId=null;points.clear();if(wasMoving&&listener!=null)listener.moveFinished(true);invalidate();}
    @Override public boolean performClick(){super.performClick();return true;}
}
