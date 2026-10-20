package com.netvistastudio.editor.android;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.Instrumentation;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.res.Configuration;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.graphics.Rect;
import android.os.Handler;
import android.os.SystemClock;
import android.util.AtomicFile;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.SeekBar;
import androidx.annotation.OptIn;
import androidx.media3.common.util.ExperimentalApi;
import androidx.media3.common.util.UnstableApi;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.File;
import java.io.FileOutputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;
import static org.junit.Assume.assumeTrue;

/** Real Home navigation, native Views, immutable authoring and compositor pixels.
 * The clean emulator receives only an in-memory verified account snapshot. */
@RunWith(AndroidJUnit4.class)
@UnstableApi
@OptIn(markerClass=ExperimentalApi.class)
public final class PhotoWorkspaceUiTest {
    @Test(timeout=150000) public void homeOpensIndependentPhotosAndNativeControlsEditActualPixels()throws Exception{
        Instrumentation instrumentation=InstrumentationRegistry.getInstrumentation();Context context=instrumentation.getTargetContext();
        assumeTrue("Use a clean emulator without a real saved login",!context.getSharedPreferences("encrypted_account",Context.MODE_PRIVATE).contains("ciphertext"));
        AtomicFile draft=new AtomicFile(new File(context.getFilesDir(),"photos/draft.netvistaphoto"));byte[] prior=draft.getBaseFile().exists()?draft.readFully():null;
        MainActivity video=null;PhotoActivity photo=null;StudioAccount account=null;StudioAccount.Snapshot originalAccount=null;int originalPhotoOrientation=ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
        Instrumentation.ActivityMonitor monitor=new Instrumentation.ActivityMonitor(PhotoActivity.class.getName(),null,false);instrumentation.addMonitor(monitor);
        try{
            PhotoEditingSession source=new PhotoEditingSession(PhotoDocument.blank(32,24,72,PhotoBitmapEngine.blank(32,24,Color.WHITE),"Background"));
            source.add(PhotoDocument.raster("Red square",PhotoBitmapEngine.blank(4,4,Color.RED)));new PhotoWorkspaceFiles(context).saveDraft(source.state());
            video=(MainActivity)instrumentation.startActivitySync(new Intent(context,MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));MainActivity videoActivity=video;
            await("Video draft restored",15000,()->onMain(instrumentation,()->(Boolean)field(videoActivity,"draftReady")));
            account=onMain(instrumentation,()->(StudioAccount)field(videoActivity,"account"));StudioAccount sharedAccount=account;
            ((ExecutorService)field(account,"worker")).submit(()->{}).get(15,TimeUnit.SECONDS);instrumentation.waitForIdleSync();originalAccount=account.state();
            onMain(instrumentation,()->{StudioAccount.Snapshot verified=new StudioAccount.Snapshot(true,false,"photos-ui@example.invalid","Native UI QA only");setField(sharedAccount,"snapshot",verified);((Handler)field(videoActivity,"main")).removeCallbacks((Runnable)field(videoActivity,"accountTimer"));invoke(videoActivity,"accountChanged",new Class[]{StudioAccount.Snapshot.class},verified);return null;});
            String videoBefore=onMain(instrumentation,()->ProjectCodec.encode((StudioProject)field(videoActivity,"project")));
            click(instrumentation,video.getWindow().getDecorView(),"Photo Editor");
            photo=(PhotoActivity)instrumentation.waitForMonitorWithTimeout(monitor,15000);assertNotNull("Actual Home button launches native PhotoActivity",photo);PhotoActivity photos=photo;originalPhotoOrientation=onMain(instrumentation,photos::getRequestedOrientation);
            await("Photo draft rendered at its current revision",15000,()->photoReady(instrumentation,photos));
            onMain(instrumentation,()->{assertTrue(photos.getWindow().getDecorView().isAttachedToWindow());PhotoCanvasView canvas=(PhotoCanvasView)field(photos,"canvas");Rect rect=new Rect();assertTrue(canvas.getGlobalVisibleRect(rect));assertTrue("Canvas remains usable",rect.height()>80*context.getResources().getDisplayMetrics().density);assertEquals(Color.RED,canvas.displayedImage().getPixel(16,12));return null;});
            assertPhotoLayout(instrumentation,photos);
            capture(instrumentation,photos,"photos-canvas",true);
            checkOtherOrientation(instrumentation,photos);
            click(instrumentation,photos.getWindow().getDecorView(),"Layers");View layers=onMain(instrumentation,()->panelRoot(photos));
            capture(instrumentation,photos,"photos-layers",false);
            Button hide=onMain(instrumentation,()->(Button)findDescription(layers,"Hide Red square"));assertNotNull("Real layer eye control",hide);onMain(instrumentation,()->{assertTrue(hide.performClick());return null;});closeSheet(instrumentation,photos);
            await("Visibility edits update displayed pixels",10000,()->photoReady(instrumentation,photos));assertPixel(instrumentation,photos,16,12,Color.WHITE);
            click(instrumentation,photos.getWindow().getDecorView(),"Undo");await("Undo restores visible source pixels",10000,()->photoReady(instrumentation,photos));assertPixel(instrumentation,photos,16,12,Color.RED);
            int beforeMove=onMain(instrumentation,()->((PhotoEditingSession)field(photos,"session")).undoCount());
            onMain(instrumentation,()->{PhotoCanvasView canvas=(PhotoCanvasView)field(photos,"canvas");gesture(canvas,canvas.getWidth()/2f,canvas.getHeight()/2f,canvas.getWidth()/2f+6*canvas.displayScale(),canvas.getHeight()/2f);return null;});
            await("Touch layer move publishes current pixels",10000,()->photoReady(instrumentation,photos));
            onMain(instrumentation,()->{PhotoEditingSession session=(PhotoEditingSession)field(photos,"session");assertEquals(6,session.selectedLayer().positionX,.15);assertEquals("One gesture produces one Undo step",beforeMove+1,session.undoCount());return null;});assertPixel(instrumentation,photos,16,12,Color.WHITE);assertPixel(instrumentation,photos,22,12,Color.RED);
            onMain(instrumentation,()->{PhotoCanvasView canvas=(PhotoCanvasView)field(photos,"canvas");float x=canvas.getWidth()/2f+6*canvas.displayScale(),y=canvas.getHeight()/2f;long now=SystemClock.uptimeMillis();MotionEvent down=MotionEvent.obtain(now,now,MotionEvent.ACTION_DOWN,x,y,0),move=MotionEvent.obtain(now,now+30,MotionEvent.ACTION_MOVE,x+4*canvas.displayScale(),y,0),cancel=MotionEvent.obtain(now,now+60,MotionEvent.ACTION_CANCEL,x+4*canvas.displayScale(),y,0);try{canvas.dispatchTouchEvent(down);canvas.dispatchTouchEvent(move);canvas.dispatchTouchEvent(cancel);}finally{down.recycle();move.recycle();cancel.recycle();}return null;});
            await("Cancelled touch drag restores the displayed original frame",10000,()->photoReady(instrumentation,photos));assertPixel(instrumentation,photos,22,12,Color.RED);
            onMain(instrumentation,()->{PhotoEditingSession session=(PhotoEditingSession)field(photos,"session");assertEquals(6,session.selectedLayer().positionX,.15);assertEquals("Cancellation creates no phantom history entry",beforeMove+1,session.undoCount());return null;});
            click(instrumentation,photos.getWindow().getDecorView(),"Properties");View properties=onMain(instrumentation,()->panelRoot(photos));SeekBar opacity=onMain(instrumentation,()->(SeekBar)findDescription(properties,"Photo Opacity"));assertNotNull(opacity);int beforeSlider=onMain(instrumentation,()->((PhotoEditingSession)field(photos,"session")).undoCount());
            capture(instrumentation,photos,"photos-properties",false);
            onMain(instrumentation,()->{opacity.requestRectangleOnScreen(new Rect(0,0,opacity.getWidth(),opacity.getHeight()),true);return null;});instrumentation.waitForIdleSync();
            onMain(instrumentation,()->{gesture(opacity,opacity.getWidth()*.7f,opacity.getHeight()/2f,opacity.getWidth()*.3f,opacity.getHeight()/2f);return null;});closeSheet(instrumentation,photos);await("Native opacity slider changes the current bitmap",10000,()->photoReady(instrumentation,photos));
            onMain(instrumentation,()->{PhotoEditingSession session=(PhotoEditingSession)field(photos,"session");assertTrue(session.selectedLayer().opacity<.5);assertEquals(beforeSlider+1,session.undoCount());int pixel=((PhotoCanvasView)field(photos,"canvas")).displayedImage().getPixel(22,12);assertEquals(255,Color.red(pixel));assertTrue("White behind red contributes real green after opacity",Color.green(pixel)>120);return null;});
            click(instrumentation,photos.getWindow().getDecorView(),"Layers");click(instrumentation,onMain(instrumentation,()->panelRoot(photos)),"+ Layer");await("New native transparent layer",10000,()->onMain(instrumentation,()->!((Boolean)field(photos,"busy"))&&((PhotoEditingSession)field(photos,"session")).state().layers.size()==3));closeSheet(instrumentation,photos);
            click(instrumentation,photos.getWindow().getDecorView(),"Brush");onMain(instrumentation,()->{PhotoCanvasView canvas=(PhotoCanvasView)field(photos,"canvas");gesture(canvas,canvas.getWidth()/2f,canvas.getHeight()/2f,canvas.getWidth()/2f+canvas.displayScale(),canvas.getHeight()/2f);return null;});
            await("Real brush stroke updates layered pixels",10000,()->photoReady(instrumentation,photos));
            onMain(instrumentation,()->{PhotoEditingSession session=(PhotoEditingSession)field(photos,"session");Bitmap own=PhotoBitmapEngine.decode(session.selectedLayer().pixels);try{assertTrue("Paint stored in selected layer, not baked display",Color.alpha(own.getPixel(16,12))>0);}finally{own.recycle();}return null;});
            String photoBefore=onMain(instrumentation,()->((PhotoEditingSession)field(photos,"session")).encodedProject());click(instrumentation,photos.getWindow().getDecorView(),"Studio Home");instrumentation.waitForIdleSync();await("Native PhotoActivity closes back to preserved Home",10000,()->onMain(instrumentation,()->photos.isFinishing()&&videoActivity.getWindow().getDecorView().hasWindowFocus()));
            assertEquals("Photo edits cannot change the Video document",videoBefore,onMain(instrumentation,()->ProjectCodec.encode((StudioProject)field(videoActivity,"project"))));
            ((ExecutorService)staticField(PhotoActivity.class,"IO")).submit(()->{}).get(20,TimeUnit.SECONDS);assertEquals(photoBefore,new PhotoWorkspaceFiles(context).readDraft());
        }finally{
            instrumentation.removeMonitor(monitor);PhotoActivity photos=photo;MainActivity videos=video;StudioAccount shared=account;StudioAccount.Snapshot original=originalAccount;int restoreOrientation=originalPhotoOrientation;
            onMain(instrumentation,()->{if(photos!=null&&!photos.isFinishing()){photos.setRequestedOrientation(restoreOrientation);photos.finish();}if(videos!=null&&!videos.isFinishing())videos.finish();return null;});instrumentation.waitForIdleSync();
            ((ExecutorService)staticField(PhotoActivity.class,"IO")).submit(()->{}).get(25,TimeUnit.SECONDS);
            if(shared!=null&&original!=null)onMain(instrumentation,()->{setField(shared,"snapshot",original);return null;});
            if(prior==null)draft.delete();else{FileOutputStream output=draft.startWrite();output.write(prior);draft.finishWrite(output);}
        }
    }
    @Test public void immutablePreparedPhotoSavesDoNotFollowLaterDraftEdits()throws Exception{
        Context context=InstrumentationRegistry.getInstrumentation().getTargetContext();PhotoWorkspaceFiles files=new PhotoWorkspaceFiles(context);
        PhotoDocument initial=PhotoDocument.blank(16,16,72,PhotoBitmapEngine.blank(16,16,Color.RED),"Red");String id=files.prepare(initial,false);
        try{PhotoEditingSession session=new PhotoEditingSession(initial);session.rename(initial.selectedLayerId,"Later name");File destination=new File(context.getCacheDir(),"photo-save-test-"+java.util.UUID.randomUUID()+".netvistaphoto");
            try{files.deliver(id,false,android.net.Uri.fromFile(destination));String saved;try(java.io.InputStream input=new java.io.FileInputStream(destination)){saved=new String(PhotoWorkspaceFiles.read(input,100000),java.nio.charset.StandardCharsets.UTF_8);}assertEquals("Captured save keeps its own layer metadata",initial.encode(),saved);assertNotEquals(session.encodedProject(),saved);}finally{assertTrue(destination.delete());}
        }finally{files.deletePending(id,false);}assertFalse(files.pendingExists(id,false));
        for(String invalid:new String[]{"../draft", "", "../../"})assertFalse(files.pendingExists(invalid,false));
    }
    private static void assertPhotoLayout(Instrumentation i,PhotoActivity photo)throws Exception{
        onMain(i,()->{PhotoCanvasView canvas=(PhotoCanvasView)field(photo,"canvas");Rect bounds=new Rect();float density=photo.getResources().getDisplayMetrics().density;
            assertTrue("Photo canvas is attached to the actual activity window",canvas.isAttachedToWindow());assertTrue(canvas.getGlobalVisibleRect(bounds));
            assertTrue("Photo canvas keeps usable height, including short landscape; actual="+bounds.height()/density+"dp",bounds.height()>80*density);
            assertTrue("Photo canvas is not clipped vertically by its panels",bounds.height()>=canvas.getHeight()-1);assertTrue("Photo canvas is not clipped horizontally",bounds.width()>=canvas.getWidth()-1);
            for(String name:new String[]{"Studio Home","Files","New","Import layer","Undo","Redo","Save","Export PNG","Move","Hand","Brush","Eraser","Brush settings"}){Button control=findButton(photo.getWindow().getDecorView(),name);assertNotNull("Real photo control: "+name,control);assertTrue("44dp native touch target: "+name,control.getHeight()>=44*density-1);}
            if((Boolean)field(photo,"wideLayout")){View panel=(View)field(photo,"panel");Rect visible=new Rect();assertTrue("Tablet panel remains reachable alongside canvas",panel.getGlobalVisibleRect(visible));assertTrue(visible.width()>=panel.getWidth()-1);}return null;});
    }
    private static void checkOtherOrientation(Instrumentation i,PhotoActivity photo)throws Exception{
        Configuration initial=onMain(i,()->new Configuration(photo.getResources().getConfiguration()));
        String document=onMain(i,()->((PhotoEditingSession)field(photo,"session")).encodedProject());int undo=onMain(i,()->((PhotoEditingSession)field(photo,"session")).undoCount());
        int other=initial.orientation==Configuration.ORIENTATION_LANDSCAPE?Configuration.ORIENTATION_PORTRAIT:Configuration.ORIENTATION_LANDSCAPE;
        requestOrientation(i,photo,other);
        try{await("Rotated photo workspace displays its current document",10000,()->photoReady(i,photo));assertPhotoLayout(i,photo);Configuration actual=onMain(i,()->new Configuration(photo.getResources().getConfiguration()));
            capture(i,photo,actual.orientation==Configuration.ORIENTATION_LANDSCAPE?"photos-landscape":"photos-portrait",true);
            click(i,photo.getWindow().getDecorView(),"Layers");onMain(i,()->{View root=panelRoot(photo);Button add=findButton(root,"+ Layer");assertNotNull("Layer controls remain usable after configuration changes",add);Rect rect=new Rect();assertTrue(add.getGlobalVisibleRect(rect));return null;});capture(i,photo,"photos-rotated-layers",false);closeSheet(i,photo);
            click(i,photo.getWindow().getDecorView(),"Properties");onMain(i,()->{SeekBar opacity=(SeekBar)findDescription(panelRoot(photo),"Photo Opacity");assertNotNull(opacity);Rect rect=new Rect();assertTrue("Rotated properties retain a visible opacity control",opacity.getGlobalVisibleRect(rect));return null;});capture(i,photo,"photos-rotated-properties",false);closeSheet(i,photo);
            assertEquals("Rotation and opening panels never modify authored photo content",document,onMain(i,()->((PhotoEditingSession)field(photo,"session")).encodedProject()));assertEquals(undo,(int)onMain(i,()->((PhotoEditingSession)field(photo,"session")).undoCount()));
            Log.i("NetVistaNativeUiChecks","Photos actual window "+actual.screenWidthDp+"x"+actual.screenHeightDp+"dp; orientation request "+(actual.orientation==other?"honored":"ignored by platform"));
        }finally{closeSheet(i,photo);requestOrientation(i,photo,initial.orientation);await("Photo canvas survives restoring its initial orientation",10000,()->photoReady(i,photo));assertPhotoLayout(i,photo);}
    }
    private static void requestOrientation(Instrumentation i,PhotoActivity photo,int target)throws Exception{
        onMain(i,()->{photo.setRequestedOrientation(target==Configuration.ORIENTATION_LANDSCAPE?ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE:ActivityInfo.SCREEN_ORIENTATION_PORTRAIT);return null;});long deadline=SystemClock.elapsedRealtime()+4000;
        // Respect Android's large-window orientation policy rather than forcing
        // global emulator state. Always inspect the actual delivered window.
        while(onMain(i,()->photo.getResources().getConfiguration().orientation)!=target&&SystemClock.elapsedRealtime()<deadline)SystemClock.sleep(40);i.waitForIdleSync();
    }
    private static void capture(Instrumentation i,PhotoActivity photo,String phase,boolean redCanvasCenter)throws Exception{
        i.waitForIdleSync();Bitmap screenshot=i.getUiAutomation().takeScreenshot();assertNotNull("Capture actual Photos device window",screenshot);
        if(screenshot.getConfig()==Bitmap.Config.HARDWARE){Bitmap readable=screenshot.copy(Bitmap.Config.ARGB_8888,false);screenshot.recycle();screenshot=readable;assertNotNull(readable);}
        try{Configuration config=onMain(i,()->new Configuration(photo.getResources().getConfiguration()));String name=phase+"_"+config.screenWidthDp+"x"+config.screenHeightDp+"dp_"+screenshot.getWidth()+"x"+screenshot.getHeight()+".png";
            // Keep the exact captured window even when a pixel/layout assertion
            // fails. This is not a drawHierarchy reconstruction of the canvas.
            QaEvidence.savePng(photo,name,screenshot);
            if(redCanvasCenter){Rect bounds=onMain(i,()->{Rect value=new Rect();assertTrue(((View)field(photo,"canvas")).getGlobalVisibleRect(value));return value;});int pixel=screenshot.getPixel(bounds.centerX(),bounds.centerY());assertTrue("Real native canvas red center is on screen: "+Integer.toHexString(pixel),Color.red(pixel)>180&&Color.green(pixel)<80&&Color.blue(pixel)<80);}
        }finally{screenshot.recycle();}
    }
    private static void assertPixel(Instrumentation i,PhotoActivity p,int x,int y,int color)throws Exception{assertEquals(color,(int)onMain(i,()->((PhotoCanvasView)field(p,"canvas")).displayedImage().getPixel(x,y)));}
    private static boolean photoReady(Instrumentation i,PhotoActivity activity)throws Exception{return onMain(i,()->{PhotoEditingSession session=(PhotoEditingSession)field(activity,"session");return (Boolean)field(activity,"ready")&&!(Boolean)field(activity,"busy")&&session!=null&&(Long)field(activity,"renderedRevision")==session.revision()&&((PhotoCanvasView)field(activity,"canvas")).displayedImage()!=null;});}
    private static View panelRoot(PhotoActivity activity)throws Exception{AlertDialog dialog=(AlertDialog)field(activity,"panelDialog");return dialog==null?activity.getWindow().getDecorView():dialog.getWindow().getDecorView();}
    private static void closeSheet(Instrumentation i,PhotoActivity activity)throws Exception{onMain(i,()->{AlertDialog dialog=(AlertDialog)field(activity,"panelDialog");if(dialog!=null)dialog.getButton(AlertDialog.BUTTON_POSITIVE).performClick();return null;});i.waitForIdleSync();}
    private static void gesture(View target,float x,float y,float endX,float endY){long start=SystemClock.uptimeMillis();MotionEvent down=MotionEvent.obtain(start,start,MotionEvent.ACTION_DOWN,x,y,0),move=MotionEvent.obtain(start,start+30,MotionEvent.ACTION_MOVE,endX,endY,0),up=MotionEvent.obtain(start,start+60,MotionEvent.ACTION_UP,endX,endY,0);try{assertTrue(target.dispatchTouchEvent(down));target.dispatchTouchEvent(move);target.dispatchTouchEvent(up);}finally{down.recycle();move.recycle();up.recycle();}}
    private static void click(Instrumentation i,View root,String text)throws Exception{Button button=onMain(i,()->{Button b=findButton(root,text);assertNotNull("Native button: "+text,b);assertTrue(b.isEnabled());b.requestRectangleOnScreen(new Rect(0,0,b.getWidth(),b.getHeight()),true);return b;});i.waitForIdleSync();onMain(i,()->{assertTrue("Native button is actually visible: "+text,button.getGlobalVisibleRect(new Rect()));assertTrue(button.performClick());return null;});i.waitForIdleSync();}
    private static Button findButton(View root,String text){if(root instanceof Button&&text.contentEquals(((Button)root).getText())&&root.isShown())return(Button)root;if(root instanceof ViewGroup){ViewGroup group=(ViewGroup)root;for(int n=0;n<group.getChildCount();n++){Button found=findButton(group.getChildAt(n),text);if(found!=null)return found;}}return null;}
    private static View findDescription(View root,String text){if(text.contentEquals(root.getContentDescription()==null?"":root.getContentDescription()))return root;if(root instanceof ViewGroup){ViewGroup group=(ViewGroup)root;for(int n=0;n<group.getChildCount();n++){View found=findDescription(group.getChildAt(n),text);if(found!=null)return found;}}return null;}
    private static Object field(Object object,String name)throws Exception{Field f=object.getClass().getDeclaredField(name);f.setAccessible(true);return f.get(object);}
    private static Object staticField(Class<?> type,String name)throws Exception{Field f=type.getDeclaredField(name);f.setAccessible(true);return f.get(null);}
    private static void setField(Object object,String name,Object value)throws Exception{Field f=object.getClass().getDeclaredField(name);f.setAccessible(true);f.set(object,value);}
    private static Object invoke(Object object,String name,Class<?>[]types,Object...args)throws Exception{Method m=object.getClass().getDeclaredMethod(name,types);m.setAccessible(true);return m.invoke(object,args);}
    private interface Condition{boolean value()throws Exception;}
    private static void await(String message,long milliseconds,Condition condition)throws Exception{long deadline=SystemClock.elapsedRealtime()+milliseconds;while(SystemClock.elapsedRealtime()<deadline){if(condition.value())return;SystemClock.sleep(40);}assertTrue(message,condition.value());}
    private static <T>T onMain(Instrumentation i,Callable<T> work)throws Exception{AtomicReference<T>result=new AtomicReference<>();AtomicReference<Throwable>failure=new AtomicReference<>();i.runOnMainSync(()->{try{result.set(work.call());}catch(Throwable error){failure.set(error);}});if(failure.get()!=null){Throwable error=failure.get();if(error instanceof Exception)throw(Exception)error;if(error instanceof Error)throw(Error)error;throw new AssertionError(error);}return result.get();}
}
