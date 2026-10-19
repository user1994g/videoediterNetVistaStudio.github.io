package com.netvistastudio.editor.android;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import android.media.ExifInterface;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.file.Files;
import java.util.UUID;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

@RunWith(AndroidJUnit4.class)
public final class PhotoImageImportTest {
    private static final long BUDGET = 16 * 1024 * 1024;

    @Test public void allEightRealJpegExifTagsOrientFullResolutionPixelsInBothNativePaths() throws Exception {
        Bitmap fixture = Bitmap.createBitmap(48, 32, Bitmap.Config.ARGB_8888);
        for (int y=0;y<fixture.getHeight();y++) for(int x=0;x<fixture.getWidth();x++)
            fixture.setPixel(x,y,y<16?(x<24?Color.RED:Color.GREEN):(x<24?Color.BLUE:Color.YELLOW));
        byte[] encoded;
        try { ByteArrayOutputStream output=new ByteArrayOutputStream(); assertTrue(fixture.compress(Bitmap.CompressFormat.JPEG,100,output)); encoded=output.toByteArray(); }
        finally { fixture.recycle(); }
        Bitmap decodedOriginal=BitmapFactory.decodeByteArray(encoded,0,encoded.length);
        int[][] corners = {
                {0,1,2,3}, // normal: top-left, top-right, bottom-left, bottom-right
                {1,0,3,2}, // flip horizontal
                {3,2,1,0}, // rotate 180
                {2,3,0,1}, // flip vertical
                {0,2,1,3}, // transpose across top-left / bottom-right
                {2,0,3,1}, // rotate 90 clockwise
                {3,1,2,0}, // transverse across top-right / bottom-left
                {1,3,0,2}  // rotate 270 clockwise
        };
        int[] samples={decodedOriginal.getPixel(8,8),decodedOriginal.getPixel(40,8),decodedOriginal.getPixel(8,24),decodedOriginal.getPixel(40,24)};
        try {
            for(int orientation=1;orientation<=8;orientation++) {
                byte[] jpeg=withOrientation(encoded,orientation);
                // This is real ExifInterface metadata, not a synthetic argument
                // passed around the importer and not pre-rotated fixture pixels.
                try(java.io.ByteArrayInputStream input=new java.io.ByteArrayInputStream(jpeg)) {
                    assertEquals(orientation,new ExifInterface(input).getAttributeInt(ExifInterface.TAG_ORIENTATION,0));
                }
                assertOriented(PhotoImageImport.decode(jpeg,BUDGET),orientation,corners[orientation-1],samples);
                assertOriented(PhotoImageImport.decodeLegacy(jpeg,BUDGET),orientation,corners[orientation-1],samples);
            }
        } finally { decodedOriginal.recycle(); }
    }

    @Test public void pngKeepsTransparentOriginalPixelsAndBudgetFailureDoesNotDownsample() throws Exception {
        Bitmap source=Bitmap.createBitmap(33,17,Bitmap.Config.ARGB_8888); source.eraseColor(Color.TRANSPARENT); source.setPixel(5,7,Color.RED); byte[] png;
        try {ByteArrayOutputStream output=new ByteArrayOutputStream();assertTrue(source.compress(Bitmap.CompressFormat.PNG,100,output));png=output.toByteArray();} finally{source.recycle();}
        for(boolean legacy:new boolean[]{false,true}) {
            Bitmap image=legacy?PhotoImageImport.decodeLegacy(png,BUDGET):PhotoImageImport.decode(png,BUDGET);
            try {assertEquals(33,image.getWidth());assertEquals(17,image.getHeight());assertEquals(Color.RED,image.getPixel(5,7));assertEquals(0,Color.alpha(image.getPixel(0,0)));assertEquals(Bitmap.Config.ARGB_8888,image.getConfig());} finally{image.recycle();}
            try {if(legacy)PhotoImageImport.decodeLegacy(png,32);else PhotoImageImport.decode(png,32);fail("Tiny budget must reject, not silently import a thumbnail");}catch(IOException expected){assertTrue(expected.getMessage().contains("working memory"));}
        }
    }

    private static byte[] withOrientation(byte[] jpeg,int orientation)throws Exception {
        File file=new File(InstrumentationRegistry.getInstrumentation().getTargetContext().getCacheDir(),"exif-qa-"+UUID.randomUUID()+".jpg");
        try {try(FileOutputStream output=new FileOutputStream(file)){output.write(jpeg);}ExifInterface exif=new ExifInterface(file.getAbsolutePath());exif.setAttribute(ExifInterface.TAG_ORIENTATION,""+orientation);exif.saveAttributes();return Files.readAllBytes(file.toPath());}
        finally {assertTrue("Own JPEG QA fixture removed",file.delete());}
    }
    private static void assertOriented(Bitmap image,int orientation,int[] order,int[] samples) {
        try {boolean swap=orientation>=5;assertEquals("Full original width after EXIF "+orientation,swap?32:48,image.getWidth());assertEquals("Full original height after EXIF "+orientation,swap?48:32,image.getHeight());assertNotEquals(Bitmap.Config.HARDWARE,image.getConfig());
            int w=image.getWidth(),h=image.getHeight();int[] actual={image.getPixel(w/6,h/4),image.getPixel(w-w/6-1,h/4),image.getPixel(w/6,h-h/4-1),image.getPixel(w-w/6-1,h-h/4-1)};
            for(int i=0;i<actual.length;i++){int expected=samples[order[i]];assertEquals("EXIF "+orientation+" red corner "+i,Color.red(expected),Color.red(actual[i]),5);assertEquals("EXIF "+orientation+" green corner "+i,Color.green(expected),Color.green(actual[i]),5);assertEquals("EXIF "+orientation+" blue corner "+i,Color.blue(expected),Color.blue(actual[i]),5);}
        } finally {image.recycle();}
    }
}
