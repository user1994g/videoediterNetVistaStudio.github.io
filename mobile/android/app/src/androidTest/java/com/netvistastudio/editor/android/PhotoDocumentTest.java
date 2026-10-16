package com.netvistastudio.editor.android;

import android.graphics.Bitmap;
import android.graphics.Color;
import android.util.Base64;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Iterator;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;
import org.junit.Test;
import org.junit.runner.RunWith;
import static org.junit.Assert.*;

/** Contract/pixel evidence for an Android photo engine foundation, not a claim
 * that Studio Home exposes a completed Android Photo workspace yet. */
@RunWith(AndroidJUnit4.class)
public final class PhotoDocumentTest {
    private static final long RENDER_BUDGET = 32 * 1024 * 1024;

    @Test public void actualAppleNativeProjectOpensRendersAndKeepsLayeredBytesOnAndroid() throws Exception {
        String saved;
        try (InputStream input = InstrumentationRegistry.getInstrumentation().getContext().getAssets().open("photo-fixtures/apple-native-v2.netvistaphoto")) {
            ByteArrayOutputStream output = new ByteArrayOutputStream(); byte[] buffer = new byte[4096]; int count;
            while ((count = input.read(buffer)) != -1) { output.write(buffer, 0, count); if (output.size() > 100000) fail("Unexpectedly large native fixture"); }
            saved = new String(output.toByteArray(), StandardCharsets.UTF_8);
        }
        PhotoDocument document = PhotoDocument.decode(saved);
        assertEquals(128, document.width); assertEquals(96, document.height); assertEquals(2, document.layers.size());
        assertEquals("Rectangle", document.layers.get(0).name); assertEquals("Layer 1", document.layers.get(1).name);
        assertEquals(10, document.layers.get(0).positionX, 0); assertEquals(15, document.layers.get(0).positionY, 0);
        assertEquals(document.layers.get(0).id, document.selectedLayerId); assertTrue(PhotoBitmapEngine.unsupportedOperations(document).isEmpty());
        Bitmap image = PhotoBitmapEngine.render(document, 0, RENDER_BUDGET);
        try {
            assertEquals("Moved Apple shape is black at document (30,35)", Color.BLACK, image.getPixel(30, 96 - 1 - 35));
            assertTrue("Apple brush stroke survives actual PNG decoding", Color.alpha(image.getPixel(64, 96 - 1 - 48)) > 230);
            assertEquals("Transparent background remains transparent", 0, Color.alpha(image.getPixel(5, 96 - 1 - 5)));
            assertEquals("The shape leaves its original position after +X/+Y movement", 0, Color.alpha(image.getPixel(12, 96 - 1 - 20)));
        } finally { image.recycle(); }
        String encoded = document.encode(); assertJsonEqual(new JSONObject(saved), new JSONObject(encoded));
        PhotoDocument reopened = PhotoDocument.decode(encoded);
        for (int index = 0; index < document.layers.size(); index++) {
            assertEquals(document.layers.get(index).id, reopened.layers.get(index).id);
            assertArrayEquals("Real UIKit PNG bytes must not be re-encoded or flattened", document.layers.get(index).pixels.png(), reopened.layers.get(index).pixels.png());
            assertJsonEqual(document.layers.get(index).properties(), reopened.layers.get(index).properties());
        }
    }

    @Test public void nativeV2KeepsEveryForeignFieldAndExactPngMaskBytes() throws Exception {
        PhotoDocument source = blank(16, 12, Color.TRANSPARENT);
        JSONObject foreign = new JSONObject(source.encode());
        foreign.put("futureDocumentMetadata", new JSONObject().put("note", "keep me"));
        JSONObject layer = foreign.getJSONArray("layers").getJSONObject(0);
        layer.put("sourcePath", "/Users/example/Original.png"); layer.put("isLocked", true); layer.put("opacity", .6);
        layer.put("blendMode", "Overlay"); layer.put("positionX", 12); layer.put("positionY", -4); layer.put("scale", 1.5); layer.put("rotation", 27);
        layer.put("futureLayerMetadata", new JSONArray().put("a").put(3));
        JSONObject a = layer.getJSONObject("adjustments");
        double[] settings = {.5,.1,1.4,.8,.2,.75,.1,4800,13,.6,2,.2,.3};
        for (int i = 0; i < settings.length; i++) a.put(PhotoDocument.ADJUSTMENT_KEYS[i], settings[i]);
        a.put("mirrored", true); a.put("futureAdjustment", .75);
        byte[] mask = PhotoBitmapEngine.blank(16, 12, Color.WHITE).png();
        JSONObject e = fullExtras(); e.put("maskPNG", Base64.encodeToString(mask, Base64.NO_WRAP)); e.put("skew", .2); e.put("hue", 30);
        e.put("black", .1); e.put("white", .9); e.put("midtone", .55); e.put("curveShadows", .3); e.put("curveHighlights", .8); e.put("noise", .2);
        e.put("text", "Editable text"); e.put("fontName", "Helvetica"); e.put("fontSize", 42); e.put("textColor", new JSONArray().put(1).put(.2).put(.3).put(.75));
        e.put("futureExtra", new JSONObject().put("value", 7)); layer.put("extras", e);
        PhotoDocument loaded = PhotoDocument.decode(foreign.toString());
        assertJsonEqual(foreign, new JSONObject(loaded.encode()));
        assertArrayEquals(source.layers.get(0).pixels.png(), loaded.layers.get(0).pixels.png()); assertArrayEquals(mask, loaded.layers.get(0).mask.png());
        JSONObject detached = loaded.layers.get(0).properties(); detached.put("name", "not a live record");
        byte[] detachedPixels = loaded.layers.get(0).pixels.png(); detachedPixels[0] = 0;
        assertEquals("Background", loaded.layers.get(0).name); assertArrayEquals(source.layers.get(0).pixels.png(), loaded.layers.get(0).pixels.png());
        PhotoDocument edited = loaded.withLayers(Arrays.asList(loaded.layers.get(0).withProperty("name", "Renamed")), loaded.selectedLayerId);
        JSONObject expected = new JSONObject(foreign.toString()); expected.getJSONArray("layers").getJSONObject(0).put("name", "Renamed");
        assertJsonEqual(expected, new JSONObject(edited.encode()));
        assertFalse("An unsupported grade must be reported, not silently omitted", PhotoBitmapEngine.unsupportedOperations(edited).isEmpty());
    }

    @Test public void failedLoadsAndCommandsKeepDocumentTransactionAndHistoryIntact() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.BLACK)); String id = session.state().selectedLayerId;
        session.opacity(id, .5); session.undo(); assertTrue(session.canRedo());
        session.beginTransaction("Brush stroke"); session.opacity(id, .8);
        PhotoDocument current = session.state(); long revision = session.revision();
        List<String> damaged = new ArrayList<>();
        JSONObject duplicate = new JSONObject(current.encode()); duplicate.getJSONArray("layers").put(new JSONObject(duplicate.getJSONArray("layers").getJSONObject(0).toString())); damaged.add(duplicate.toString());
        JSONObject badScale = new JSONObject(current.encode()); badScale.getJSONArray("layers").getJSONObject(0).put("scale", 0); damaged.add(badScale.toString());
        JSONObject badOpacity = new JSONObject(current.encode()); badOpacity.getJSONArray("layers").getJSONObject(0).put("opacity", 1.1); damaged.add(badOpacity.toString());
        JSONObject badBoolean = new JSONObject(current.encode()); badBoolean.getJSONArray("layers").getJSONObject(0).put("isLocked", "false"); damaged.add(badBoolean.toString());
        JSONObject badName = new JSONObject(current.encode()); badName.getJSONArray("layers").getJSONObject(0).put("name", 123); damaged.add(badName.toString());
        JSONObject badPath = new JSONObject(current.encode()); badPath.getJSONArray("layers").getJSONObject(0).put("sourcePath", true); damaged.add(badPath.toString());
        JSONObject nullExtra = new JSONObject(current.encode()); nullExtra.getJSONArray("layers").getJSONObject(0).put("extras", fullExtras().put("skew", JSONObject.NULL)); damaged.add(nullExtra.toString());
        JSONObject badText = new JSONObject(current.encode()); badText.getJSONArray("layers").getJSONObject(0).put("extras", fullExtras().put("text", 123)); damaged.add(badText.toString());
        JSONObject badCanvas = new JSONObject(current.encode()); badCanvas.put("canvasWidth", 8.5); damaged.add(badCanvas.toString());
        JSONObject legacy = new JSONObject(current.encode()); legacy.put("version", 1); damaged.add(legacy.toString());
        byte[] corrupt = current.layers.get(0).pixels.png(); corrupt[corrupt.length / 2] ^= 1;
        JSONObject badPixels = new JSONObject(current.encode()); badPixels.getJSONArray("layers").getJSONObject(0).put("pixels", Base64.encodeToString(corrupt, Base64.NO_WRAP)); damaged.add(badPixels.toString());
        damaged.add("{broken");
        for (String input : damaged) {
            try { session.load(input); fail("Accepted a malformed photo document"); } catch (IOException expected) { /* required */ }
            assertSame(current, session.state()); assertEquals(revision, session.revision()); assertTrue(session.isEditing()); assertEquals(0, session.undoCount()); assertEquals(1, session.redoCount());
        }
        try { session.opacity(id, Double.NaN); fail("Accepted a nonfinite photo edit"); } catch (IOException expected) { /* required */ }
        assertSame(current, session.state()); session.cancelTransaction(); assertEquals(1, session.selectedLayer().opacity, 0); assertTrue(session.canRedo());
        assertTrue(session.redo()); assertEquals(.5, session.selectedLayer().opacity, 0);
    }

    @Test public void gestureHistoryIsSingleStepAndStructuralCommandsKeepCapturedLayerIdentity() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.BLACK)); String original = session.state().selectedLayerId;
        session.beginTransaction("Opacity drag"); for (double opacity : new double[]{.9,.8,.7,.6,.5}) session.opacity(original, opacity); session.finishTransaction();
        assertEquals(1, session.undoCount()); assertTrue(session.undo()); assertEquals(1, session.selectedLayer().opacity, 0);
        assertTrue(session.redo()); assertEquals(.5, session.selectedLayer().opacity, 0);
        session.beginTransaction("Move drag"); session.position(original, 2, 3); String duplicate = session.duplicate(original);
        assertFalse(session.isEditing()); assertEquals(3, session.undoCount()); assertNotEquals(original, duplicate);
        assertTrue(session.undo()); assertEquals(1, session.state().layers.size()); assertEquals(2, session.selectedLayer().positionX, 0);
        assertTrue(session.undo()); assertEquals(0, session.selectedLayer().positionX, 0); assertEquals(.5, session.selectedLayer().opacity, 0);
        session.redo(); session.redo(); session.remove(original); PhotoDocument current = session.state(); int history = session.undoCount();
        try { session.position(original, 40, 50); fail("A stale tool edited a removed layer"); } catch (IOException expected) { /* required */ }
        assertSame(current, session.state()); assertEquals(history, session.undoCount()); assertEquals(2, session.selectedLayer().positionX, 0);
        session.select(null); assertNull(session.state().selectedLayerId);
        session.opacity(duplicate, .75); assertNull("A captured-layer command must preserve deliberate deselection", session.state().selectedLayerId);
    }

    @Test public void foldersMoveAsBlocksAndLocksMasksAndCopiesRemainIndependent() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.BLACK)); String background = session.state().selectedLayerId;
        String red = session.add(PhotoDocument.raster("Red", PhotoBitmapEngine.blank(8, 8, Color.RED)));
        PhotoDocument.Pixels mask = PhotoBitmapEngine.blank(8, 8, Color.WHITE); session.mask(red, mask);
        String folder = session.group(Arrays.asList(red, background), "Folder", PhotoBitmapEngine.blank(1, 1, Color.TRANSPARENT));
        assertEquals(folder, session.state().layers.get(0).id); assertEquals(red, session.state().layers.get(1).id); assertEquals(background, session.state().layers.get(2).id);
        session.locked(folder, true); PhotoDocument locked = session.state();
        try { session.rename(red, "Forbidden"); fail("Edited through a locked folder"); } catch (IOException expected) { /* required */ }
        assertSame(locked, session.state()); session.visible(folder, false); assertFalse(session.state().layer(folder).visible);
        session.locked(folder, false); session.visible(folder, true);
        String copy = session.duplicate(folder); assertEquals(6, session.state().layers.size());
        PhotoDocument.Layer copiedRed = session.state().layers.get(1); assertNotEquals(red, copiedRed.id); assertEquals(copy, copiedRed.groupId);
        assertSame("Metadata copies share immutable compressed pixels", mask, copiedRed.mask);
        session.mask(copiedRed.id, null); assertNotNull(session.state().layer(red).mask); assertNull(session.state().layer(copiedRed.id).mask);
        session.reorder(copy, 1); assertEquals(folder, session.state().layers.get(0).id); assertEquals(copy, session.state().layers.get(3).id);
        session.remove(copy); assertEquals(3, session.state().layers.size()); assertNotNull(session.state().layer(red));
        session.ungroup(folder); assertEquals(2, session.state().layers.size()); assertNull(session.state().layer(red).groupId);
        // Android-created masks/folders must emit every nonoptional Swift Codable extras field.
        JSONObject saved = new JSONObject(session.encodedProject()); JSONObject extras = saved.getJSONArray("layers").getJSONObject(0).getJSONObject("extras");
        for (String key : new String[]{"isGroup", "isAdjustment", "skew", "hue", "black", "white", "midtone", "curveShadows", "curveHighlights", "noise"}) assertTrue(key, extras.has(key));
        PhotoDocument reopened = PhotoDocument.decode(session.encodedProject()); assertEquals(red, reopened.layers.get(0).id); assertArrayEquals(mask.png(), reopened.layers.get(0).mask.png());
    }

    @Test public void nativePixelsMatchOpacityMaskLayerOrderAndPositiveYUpPlacement() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(16, 16, Color.BLACK));
        String red = session.add(PhotoDocument.raster("Red", PhotoBitmapEngine.blank(4, 4, Color.RED))); session.position(red, 2, 3); session.opacity(red, .5);
        Bitmap image = PhotoBitmapEngine.render(session.state(), 0, RENDER_BUDGET);
        try {
            int center = image.getPixel(10, 5); assertEquals(255, Color.alpha(center)); assertEquals(188, Color.red(center), 1); assertEquals(0, Color.green(center));
            assertEquals("+Y moves up in the real Android image", Color.BLACK, image.getPixel(10, 11)); assertEquals(Color.BLACK, image.getPixel(0, 0));
        } finally { image.recycle(); }
        Bitmap mask = Bitmap.createBitmap(4, 4, Bitmap.Config.ARGB_8888); mask.eraseColor(Color.BLACK);
        for (int y = 0; y < 4; y++) for (int x = 0; x < 2; x++) mask.setPixel(x, y, Color.WHITE);
        try { session.mask(red, PhotoBitmapEngine.pixels(mask)); } finally { mask.recycle(); }
        image = PhotoBitmapEngine.render(session.state(), 0, RENDER_BUDGET);
        try { assertEquals(188, Color.red(image.getPixel(9, 5)), 1); assertEquals("Black mask removes only the masked half", Color.BLACK, image.getPixel(11, 5)); }
        finally { image.recycle(); }
        PhotoDocument reopened = PhotoDocument.decode(session.encodedProject()); image = PhotoBitmapEngine.render(reopened, 0, RENDER_BUDGET);
        try { assertEquals(188, Color.red(image.getPixel(9, 5)), 1); assertEquals(Color.BLACK, image.getPixel(11, 5)); }
        finally { image.recycle(); }
        session.visible(red, false); image = PhotoBitmapEngine.render(session.state(), 0, RENDER_BUDGET);
        try { assertEquals(Color.BLACK, image.getPixel(9, 5)); } finally { image.recycle(); }
    }

    @Test public void sourceDocumentTransformsInvertAndMatchNativeCanvasCoordinates() throws Exception {
        PhotoDocument document = blank(32, 24, Color.TRANSPARENT);
        PhotoDocument.Layer layer = document.layers.get(0).withProperty("positionX", 2).withProperty("positionY", 3).withProperty("scale", 2).withProperty("rotation", 90);
        JSONObject encoded = new JSONObject(document.withLayers(Arrays.asList(layer), layer.id).encode()); encoded.getJSONArray("layers").getJSONObject(0).put("extras", fullExtras().put("skew", .25));
        document = PhotoDocument.decode(encoded.toString()); layer = document.layers.get(0);
        for (double[] source : new double[][]{{0,0},{7.25,4.5},{32,24}}) {
            double[] point = layer.documentPoint(source[0], source[1], document.width, document.height);
            double[] inverse = layer.sourcePoint(point[0], point[1], document.width, document.height);
            assertArrayEquals(source, inverse, 0.0000001);
            float[] nativePoint = {(float)source[0], (float)(layer.pixels.height - source[1])}; PhotoBitmapEngine.transform(layer, document, .5).mapPoints(nativePoint);
            assertEquals(point[0] * .5, nativePoint[0], .0001); assertEquals((document.height - point[1]) * .5, nativePoint[1], .0001);
        }
    }

    @Test public void folderReferencesAcceptUuidCaseAndDeviceLoadBudgetRejectsBeforePublication() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.BLACK)); String background = session.state().selectedLayerId;
        String top = session.add(PhotoDocument.raster("Top", PhotoBitmapEngine.blank(8, 8, Color.RED)));
        String folder = session.group(Arrays.asList(top, background), "Folder", PhotoBitmapEngine.blank(1, 1, Color.TRANSPARENT));
        JSONObject mixed = new JSONObject(session.encodedProject()); mixed.getJSONArray("layers").getJSONObject(1).getJSONObject("extras").put("groupID", folder.toUpperCase(java.util.Locale.ROOT));
        session.load(mixed.toString()); session.reorder(top, 1);
        assertEquals(background, session.state().layers.get(1).id); assertEquals(top, session.state().layers.get(2).id);
        String preserved = session.encodedProject();
        try { PhotoDocument.decode(preserved, 1); fail("Ignored the device load-memory budget"); } catch (IOException expected) { assertTrue(expected.getMessage().contains("memory")); }
        assertEquals(preserved, session.encodedProject());
    }

    @Test public void rendererRejectsUnsupportedSavedOperationsAndMemoryBudgetWithoutMutatingDocument() throws Exception {
        PhotoDocument document = blank(8, 8, Color.BLACK); PhotoDocument.Layer layer = document.layers.get(0).withAdjustment("vibrance", .5).withAdjustment("blur", 2);
        document = document.withLayers(Arrays.asList(layer), layer.id); String preserved = document.encode();
        assertTrue(PhotoBitmapEngine.unsupportedOperations(document).contains("Adjustment: vibrance")); assertTrue(PhotoBitmapEngine.unsupportedOperations(document).contains("Adjustment: blur"));
        try { PhotoBitmapEngine.render(document, 0, RENDER_BUDGET); fail("Rendered while silently dropping unsupported grade data"); }
        catch (IOException expected) { assertTrue(expected.getMessage().contains("remains intact")); }
        assertEquals(preserved, document.encode());
        PhotoDocument neutral = blank(8, 8, Color.BLACK); String original = neutral.encode();
        try { PhotoBitmapEngine.render(neutral, 0, 1); fail("Exceeded explicit memory budget"); } catch (IOException expected) { assertTrue(expected.getMessage().contains("memory")); }
        assertEquals(original, neutral.encode());
    }

    @Test public void historySharesPixelAllocationsAndRetainsTheMostRecentPaintUndoWithinBudget() throws Exception {
        PhotoEditingSession session = new PhotoEditingSession(blank(8, 8, Color.BLACK), 12, 1); String id = session.state().selectedLayerId;
        for (int index = 0; index < 20; index++) session.position(id, index, index); assertEquals("Metadata history does not duplicate image memory", 12, session.undoCount());
        PhotoDocument.Pixels before = session.selectedLayer().pixels;
        session.beginTransaction("Stroke"); session.pixels(id, PhotoBitmapEngine.blank(8, 8, Color.RED)); session.pixels(id, PhotoBitmapEngine.blank(8, 8, Color.BLUE)); session.finishTransaction();
        assertEquals("Older allocations are bounded while keeping the latest reversible stroke", 1, session.undoCount());
        assertTrue(session.undo()); assertSame(before, session.selectedLayer().pixels); assertTrue(session.redo());
        Bitmap decoded = PhotoBitmapEngine.decode(session.selectedLayer().pixels); try { assertEquals(Color.BLUE, decoded.getPixel(4, 4)); } finally { decoded.recycle(); }
    }

    private static PhotoDocument blank(int width, int height, int color) throws IOException { return PhotoDocument.blank(width, height, 72, PhotoBitmapEngine.blank(width, height, color), "Background"); }
    private static JSONObject fullExtras() throws Exception {
        JSONObject result = new JSONObject().put("isGroup", false).put("isAdjustment", false);
        for (String key : new String[]{"skew", "hue", "black", "white", "midtone", "curveShadows", "curveHighlights", "noise"}) result.put(key, PhotoDocument.extraDefault(key)); return result;
    }
    private static void assertJsonEqual(Object expected, Object actual) throws Exception {
        if (expected instanceof JSONObject) {
            assertTrue(actual instanceof JSONObject); JSONObject left = (JSONObject) expected, right = (JSONObject) actual; assertEquals(left.length(), right.length());
            Iterator<String> keys = left.keys(); while (keys.hasNext()) { String key = keys.next(); assertTrue(key, right.has(key)); assertJsonEqual(left.get(key), right.get(key)); }
        } else if (expected instanceof JSONArray) {
            assertTrue(actual instanceof JSONArray); JSONArray left = (JSONArray) expected, right = (JSONArray) actual; assertEquals(left.length(), right.length()); for (int i = 0; i < left.length(); i++) assertJsonEqual(left.get(i), right.get(i));
        } else if (expected instanceof Number) { assertTrue(actual instanceof Number); assertEquals(((Number) expected).doubleValue(), ((Number) actual).doubleValue(), 0); }
        else assertEquals(expected, actual);
    }
}
