package com.netvistastudio.editor.android;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Color;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Real native PNG pixels, not a mock renderer or a flattened replacement for
 * the shared layered project. Android's affine resampling and unverified Core
 * Image-only filters are not advertised as exact cross-platform parity.
 */
@RunWith(AndroidJUnit4.class)
public final class PhotoCompositorTest {
    private static final long BUDGET = 32 * 1024 * 1024;

    @Test public void actualMacProjectAndProductionPngAgreeForAllEightBlends() throws Exception {
        String source = new String(asset("apple-blends-v2.netvistaphoto"), StandardCharsets.UTF_8);
        PhotoDocument document = PhotoDocument.decode(source); String before = document.encode();
        assertEquals(64, document.width); assertEquals(8, document.height); assertEquals(16, document.layers.size());
        assertTrue(PhotoBitmapEngine.unsupportedOperations(document).isEmpty());
        byte[] expectedPng = asset("apple-blends-v2.png"); Bitmap expected = BitmapFactory.decodeByteArray(expectedPng, 0, expectedPng.length);
        assertNotNull("Actual Mac compositor reference PNG decodes", expected);
        Bitmap actual = PhotoBitmapEngine.render(document, 0, BUDGET), preview = null;
        try {
            String[] modes = {"Normal", "Multiply", "Screen", "Overlay", "Soft Light", "Darken", "Lighten", "Color Dodge"};
            for (int index = 0; index < modes.length; index++) {
                assertEquals(modes[index], document.layers.get(index).blendMode);
                assertColour("Actual Mac/Android " + modes[index] + " PNG sample", expected.getPixel(index * 8 + 4, 4), actual.getPixel(index * 8 + 4, 4), 2);
            }
            preview = PhotoBitmapEngine.render(document, 32, BUDGET); assertEquals(32, preview.getWidth()); assertEquals(4, preview.getHeight());
            for (int index = 0; index < modes.length; index++) assertColour("Bounded preview retains " + modes[index], expected.getPixel(index * 8 + 4, 4), preview.getPixel(index * 4 + 2, 2), 2);
        } finally { actual.recycle(); expected.recycle(); if (preview != null) preview.recycle(); }
        assertEquals("Rendering never flattens, re-encodes or mutates the document", before, document.encode());
        PhotoDocument reopened = PhotoDocument.decode(document.encode());
        for (int index = 0; index < document.layers.size(); index++) assertArrayEquals(document.layers.get(index).pixels.png(), reopened.layers.get(index).pixels.png());
    }

    @Test public void actualMacPrimaryColourAndLevelsPngAgreeWithNativeLinearProcessing() throws Exception {
        PhotoDocument document = PhotoDocument.decode(new String(asset("apple-colour-v2.netvistaphoto"), StandardCharsets.UTF_8));
        assertEquals(48, document.width); assertEquals(6, document.layers.size()); assertTrue(PhotoBitmapEngine.unsupportedOperations(document).isEmpty());
        String before = document.encode(); byte[] reference = asset("apple-colour-v2.png");
        Bitmap expected = BitmapFactory.decodeByteArray(reference, 0, reference.length), actual = PhotoBitmapEngine.render(document, 0, BUDGET);
        assertNotNull(expected);
        try {
            for (int index = 0; index < document.layers.size(); index++) assertColour("Actual Mac " + document.layers.get(index).name + " grade", expected.getPixel(index * 8 + 4, 4), actual.getPixel(index * 8 + 4, 4), 2);
        } finally { expected.recycle(); actual.recycle(); }
        assertEquals(before, document.encode());
    }

    @Test public void isolatedFolderOpacityIsAppliedOnceAfterItsChildrenAndVisibilityHidesTheWholeFolder() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.BLUE));
        String red = session.add(PhotoDocument.raster("Red", PhotoBitmapEngine.blank(8, 8, Color.RED)));
        String green = session.add(PhotoDocument.raster("Green", PhotoBitmapEngine.blank(8, 8, Color.GREEN)));
        String folder = session.group(Arrays.asList(green, red), "Isolated folder", PhotoBitmapEngine.blank(1, 1, Color.TRANSPARENT));
        session.opacity(folder, .5); String before = session.encodedProject();
        Bitmap image = PhotoBitmapEngine.render(session.state(), 0, BUDGET);
        try {
            int pixel = image.getPixel(4, 4); assertEquals(0, Color.red(pixel)); assertEquals(188, Color.green(pixel), 1); assertEquals(188, Color.blue(pixel), 1); assertEquals(255, Color.alpha(pixel));
        } finally { image.recycle(); }
        assertEquals(before, session.encodedProject()); session.visible(folder, false);
        image = PhotoBitmapEngine.render(session.state(), 0, BUDGET); try { assertEquals(Color.BLUE, image.getPixel(4, 4)); } finally { image.recycle(); }
        session.visible(folder, true); session.opacity(folder, 1); session.locked(folder, true);
        image = PhotoBitmapEngine.render(session.state(), 0, BUDGET); try { assertEquals("Locking does not hide folder pixels", Color.GREEN, image.getPixel(4, 4)); } finally { image.recycle(); }
    }

    @Test public void adjustmentMaskAndOpacityMixAfterGradingAndIgnoreLayerPlacement() throws Exception {
        PhotoDocument document = blank(8, 8, Color.rgb(137, 137, 137));
        PhotoDocument.Layer adjustment = PhotoDocument.raster("Exposure adjustment", PhotoBitmapEngine.blank(8, 8, Color.TRANSPARENT))
                .withAdjustment("exposure", 1).withProperty("opacity", .5).withProperty("positionX", 100).withProperty("scale", 2).withProperty("rotation", 90);
        Bitmap mask = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888); mask.eraseColor(Color.BLACK);
        for (int y = 0; y < 8; y++) for (int x = 0; x < 4; x++) mask.setPixel(x, y, Color.WHITE);
        try { adjustment = adjustment.withMask(PhotoBitmapEngine.pixels(mask)); } finally { mask.recycle(); }
        document = top(document, adjustment); document = extra(document, adjustment.id, "isAdjustment", true); String before = document.encode();
        Bitmap image = PhotoBitmapEngine.render(document, 0, BUDGET);
        try {
            int expected = encoded(linear(137) * 1.5);
            assertColour("Half-opacity grade on revealed mask side", Color.rgb(expected, expected, expected), image.getPixel(1, 4), 1);
            assertEquals("Black side retains ungraded source despite adjustment-layer transforms", Color.rgb(137, 137, 137), image.getPixel(6, 4));
        } finally { image.recycle(); }
        assertEquals(before, document.encode());
    }

    @Test public void groupedAdjustmentOnlyGradesItsIsolatedChildrenAndNeverFillsTransparentPixels() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.BLUE));
        String child = session.add(PhotoDocument.raster("Small red", PhotoBitmapEngine.blank(4, 4, Color.RED)));
        PhotoDocument.Layer adjustment = PhotoDocument.raster("Desaturate", PhotoBitmapEngine.blank(8, 8, Color.TRANSPARENT)).withAdjustment("saturation", 0);
        String adjust = session.add(adjustment); PhotoDocument state = extra(session.state(), adjust, "isAdjustment", true);
        session = new PhotoEditingSession(state); session.group(Arrays.asList(adjust, child), "Child-only adjustment", PhotoBitmapEngine.blank(1, 1, Color.TRANSPARENT));
        Bitmap image = PhotoBitmapEngine.render(session.state(), 0, BUDGET);
        try {
            int gray = encoded(.2126); assertColour("Group-local adjustment grades its red child", Color.rgb(gray, gray, gray), image.getPixel(4, 4), 1);
            assertEquals("Transparent group area does not grade a root sibling or gain opacity", Color.BLUE, image.getPixel(0, 0));
        } finally { image.recycle(); }
    }

    @Test public void mirrorHappensBeforeTheStationaryPostFlipMaskWithoutChangingStoredPng() throws Exception {
        Bitmap raster = Bitmap.createBitmap(8, 4, Bitmap.Config.ARGB_8888), mask = Bitmap.createBitmap(8, 4, Bitmap.Config.ARGB_8888);
        for (int y = 0; y < 4; y++) for (int x = 0; x < 8; x++) { raster.setPixel(x, y, x < 4 ? Color.RED : Color.BLUE); mask.setPixel(x, y, x < 4 ? Color.WHITE : Color.BLACK); }
        PhotoDocument.Pixels source, coverage;
        try { source = PhotoBitmapEngine.pixels(raster); coverage = PhotoBitmapEngine.pixels(mask); } finally { raster.recycle(); mask.recycle(); }
        PhotoDocument document = PhotoDocument.blank(8, 4, 72, source, "Mirrored source"); String id = document.selectedLayerId;
        document = replace(document, document.layer(id).withMask(coverage)); document = setting(document, id, "mirrored", true); String before = document.encode();
        Bitmap image = PhotoBitmapEngine.render(document, 0, BUDGET);
        try { assertEquals("The source's right-hand blue moves left", Color.BLUE, image.getPixel(1, 2)); assertEquals("Mask remains fixed, so original red is hidden on the right", 0, Color.alpha(image.getPixel(6, 2))); }
        finally { image.recycle(); }
        assertEquals(before, document.encode()); assertArrayEquals(source.png(), document.layer(id).pixels.png()); assertArrayEquals(coverage.png(), document.layer(id).mask.png());
    }

    @Test public void fractionalAlphaBlendsStayPremultipliedAndDoNotExposeHiddenRgb() throws Exception {
        PhotoDocument document = blank(4, 4, Color.argb(128, 0, 0, 255));
        PhotoDocument.Layer foreground = PhotoDocument.raster("Half alpha red", PhotoBitmapEngine.blank(4, 4, Color.argb(128, 255, 0, 0))).withProperty("blendMode", "Multiply").withProperty("opacity", .5);
        document = top(document, foreground); Bitmap image = PhotoBitmapEngine.render(document, 0, BUDGET);
        try {
            double back = 128 / 255.0, front = back * .5, alpha = front + back * (1 - front);
            int expected = Color.argb((int)Math.round(alpha * 255), encoded(front * (1 - back) / alpha), 0, encoded(back * (1 - front) / alpha));
            assertColour("Porter-Duff alpha around the real Multiply operation", expected, image.getPixel(2, 2), 2);
        } finally { image.recycle(); }
        PhotoDocument transparent = blank(4, 4, Color.TRANSPARENT);
        image = PhotoBitmapEngine.render(top(transparent, foreground.withProperty("opacity", 0)), 0, BUDGET);
        try { assertEquals("Zero-opacity data must not contribute colour or alpha", 0, image.getPixel(2, 2)); } finally { image.recycle(); }
    }

    @Test public void basicColourAndLevelsUseLinearValuesAndDoNotClipRecoverableExposureBetweenLayers() throws Exception {
        PhotoDocument document = blank(8, 8, Color.rgb(137, 96, 32)); String id = document.selectedLayerId;
        document = replace(document, document.layer(id).withAdjustment("exposure", .5).withAdjustment("saturation", 0).withAdjustment("contrast", .7).withAdjustment("brightness", .1));
        document = extra(extra(document, id, "black", .1), id, "white", .9);
        double luma = (.2126 * linear(137) + .7152 * linear(96) + .0722 * linear(32)) * Math.sqrt(2);
        int gray = encoded(((luma - .5) * .7 + .5 + .1 - .1) / .8);
        Bitmap image = PhotoBitmapEngine.render(document, 0, BUDGET);
        try { assertColour("Exposure, saturation, contrast/brightness and levels remain ordered", Color.rgb(gray, gray, gray), image.getPixel(4, 4), 1); }
        finally { image.recycle(); }
        PhotoDocument hdr = blank(8, 8, Color.rgb(188, 188, 188)); hdr = replace(hdr, hdr.layers.get(0).withAdjustment("exposure", 2));
        PhotoDocument.Layer recover = PhotoDocument.raster("Recover range", PhotoBitmapEngine.blank(8, 8, Color.TRANSPARENT)).withAdjustment("exposure", -2);
        hdr = extra(top(hdr, recover), recover.id, "isAdjustment", true);
        image = PhotoBitmapEngine.render(hdr, 0, BUDGET);
        try { assertColour("An upper adjustment recovers an unclipped lower exposure", Color.rgb(188, 188, 188), image.getPixel(4, 4), 1); } finally { image.recycle(); }
    }

    @Test public void supportedRenderingIsAtomicAndVendorSpecificFiltersRemainExplicitlyUnsupported() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.RED)); String id = session.state().selectedLayerId;
        session.opacity(id, .7); session.undo(); assertTrue(session.canRedo()); PhotoDocument original = session.state(); String before = session.encodedProject(); long revision = session.revision();
        for (String key : new String[]{"vibrance", "highlights", "temperature", "blur"}) {
            double value = key.equals("temperature") ? 4800 : key.equals("highlights") ? .7 : .5;
            PhotoDocument unsupported = replace(original, original.layer(id).withAdjustment(key, value)); String saved = unsupported.encode();
            assertTrue(PhotoBitmapEngine.unsupportedOperations(unsupported).contains("Adjustment: " + key));
            try { PhotoBitmapEngine.render(unsupported, 0, BUDGET); fail("Silently omitted " + key); } catch (IOException expected) { assertTrue(expected.getMessage().contains("remains intact")); }
            assertEquals(saved, unsupported.encode());
        }
        try { PhotoBitmapEngine.render(original, 0, 1); fail("Ignored the explicit memory budget"); } catch (IOException expected) { assertTrue(expected.getMessage().contains("memory")); }
        assertSame(original, session.state()); assertEquals(before, session.encodedProject()); assertEquals(revision, session.revision()); assertTrue(session.canRedo()); assertEquals(0, session.undoCount());
    }

    private static byte[] asset(String name) throws IOException {
        try (InputStream input = InstrumentationRegistry.getInstrumentation().getContext().getAssets().open("photo-fixtures/" + name); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            ProjectFiles.copy(input, output, 100000); return output.toByteArray();
        }
    }
    private static PhotoDocument blank(int width, int height, int color) throws IOException { return PhotoDocument.blank(width, height, 72, PhotoBitmapEngine.blank(width, height, color), "Background"); }
    private static PhotoDocument top(PhotoDocument document, PhotoDocument.Layer layer) throws IOException { List<PhotoDocument.Layer> layers = new ArrayList<>(document.layers); layers.add(0, layer); return document.withLayers(layers, layer.id); }
    private static PhotoDocument replace(PhotoDocument document, PhotoDocument.Layer layer) throws IOException { List<PhotoDocument.Layer> layers = new ArrayList<>(document.layers); for (int i = 0; i < layers.size(); i++) if (layers.get(i).id.equalsIgnoreCase(layer.id)) layers.set(i, layer); return document.withLayers(layers, document.selectedLayerId); }
    private static PhotoDocument setting(PhotoDocument document, String id, String key, Object value) throws Exception { return jsonEdit(document, id, "adjustments", key, value); }
    private static PhotoDocument extra(PhotoDocument document, String id, String key, Object value) throws Exception { return jsonEdit(document, id, "extras", key, value); }
    private static PhotoDocument jsonEdit(PhotoDocument document, String id, String section, String key, Object value) throws Exception {
        JSONObject saved = new JSONObject(document.encode()); JSONArray layers = saved.getJSONArray("layers");
        for (int i = 0; i < layers.length(); i++) { JSONObject layer = layers.getJSONObject(i); if (!id.equalsIgnoreCase(layer.getString("id"))) continue;
            JSONObject properties = layer.optJSONObject(section); if (properties == null) { properties = new JSONObject(); layer.put(section, properties); } properties.put(key, value);
        }
        return PhotoDocument.decode(saved.toString());
    }
    private static double linear(int value) { double c = value / 255.0; return c <= .04045 ? c / 12.92 : Math.pow((c + .055) / 1.055, 2.4); }
    private static int encoded(double value) { double c = Math.max(0, Math.min(1, value)); return (int)Math.round(255 * (c <= .0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - .055)); }
    private static void assertColour(String message, int expected, int actual, int tolerance) {
        for (int shift : new int[]{24, 16, 8, 0}) assertEquals(message + " (channel " + shift + ")", (expected >>> shift) & 255, (actual >>> shift) & 255, tolerance);
    }
}
