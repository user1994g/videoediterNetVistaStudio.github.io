package com.netvistastudio.editor.android;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.PorterDuff;
import android.graphics.PorterDuffXfermode;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;

/** Native PNG/Canvas adapter and the first verified compositing operations.
 * Unsupported saved grades, blend modes or folders are rejected explicitly.
 * Source-over colour is evaluated in linear sRGB, not Android's default encoded
 * channel blending. Canvas currently supplies native transform/resampling only.
 */
public final class PhotoBitmapEngine {
    private static final float[] LINEAR = new float[256];
    static { for (int i = 0; i < LINEAR.length; i++) { double value = i / 255.0; LINEAR[i] = (float)(value <= .04045 ? value / 12.92 : Math.pow((value + .055) / 1.055, 2.4)); } }
    private PhotoBitmapEngine() {}

    public static List<String> unsupportedOperations(PhotoDocument document) throws IOException {
        List<String> result = new ArrayList<>();
        for (PhotoDocument.Layer layer : document.layers) {
            if (layer.pixels.bitDepth > 8 || layer.mask != null && layer.mask.bitDepth > 8) add(result, "16-bit PNG processing");
            if (layer.group) add(result, "Layer folders");
            if (layer.adjustment) add(result, "Adjustment layers");
            if (!layer.blendMode.equals("Normal")) add(result, "Blend mode: " + layer.blendMode);
            try {
                JSONObject value = layer.properties(), a = value.getJSONObject("adjustments");
                List<String> knownLayer = Arrays.asList("id", "name", "sourcePath", "isVisible", "isLocked", "opacity", "blendMode", "positionX", "positionY", "scale", "rotation", "adjustments", "extras");
                Iterator<String> layerKeys = value.keys(); while (layerKeys.hasNext()) { String key = layerKeys.next(); if (!knownLayer.contains(key)) add(result, "Unrecognised layer field: " + key); }
                for (int i = 0; i < PhotoDocument.ADJUSTMENT_DEFAULTS.length; i++)
                    if (a.getDouble(PhotoDocument.ADJUSTMENT_KEYS[i]) != PhotoDocument.ADJUSTMENT_DEFAULTS[i]) add(result, "Adjustment: " + PhotoDocument.ADJUSTMENT_KEYS[i]);
                if (a.getBoolean("mirrored")) add(result, "Image mirror");
                Iterator<String> keys = a.keys(); while (keys.hasNext()) { String key = keys.next(); if (!Arrays.asList(PhotoDocument.ADJUSTMENT_KEYS).contains(key)) add(result, "Unrecognised adjustment: " + key); }
                JSONObject e = value.optJSONObject("extras");
                if (e != null) {
                    for (String key : new String[]{"hue", "black", "white", "midtone", "curveShadows", "curveHighlights", "noise"})
                        if (e.has(key) && !e.isNull(key) && e.getDouble(key) != PhotoDocument.extraDefault(key)) add(result, "Adjustment: " + key);
                    List<String> known = Arrays.asList("groupID", "isGroup", "isAdjustment", "maskPNG", "skew", "hue", "black", "white", "midtone", "curveShadows", "curveHighlights", "noise", "text", "fontName", "fontSize", "textColor");
                    keys = e.keys(); while (keys.hasNext()) { String key = keys.next(); if (!known.contains(key)) add(result, "Unrecognised layer property: " + key); }
                }
            } catch (JSONException error) { throw PhotoDocument.invalid("Invalid native photo settings", error); }
        }
        return Collections.unmodifiableList(result);
    }
    private static void add(List<String> values, String value) { if (!values.contains(value)) values.add(value); }
    public static void requireSupported(PhotoDocument document) throws IOException {
        List<String> unsupported = unsupportedOperations(document);
        if (!unsupported.isEmpty()) throw new IOException("This Android photo renderer does not yet implement " + android.text.TextUtils.join(", ", unsupported) + ". The saved project data remains intact.");
    }
    public static PhotoDocument.Pixels blank(int width, int height, int color) throws IOException {
        PhotoDocument.validateSize(width, height); Bitmap bitmap = null;
        try { bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888); bitmap.eraseColor(color); return pixels(bitmap); }
        catch (OutOfMemoryError error) { throw new IOException("This device has insufficient memory for that canvas. Choose a smaller canvas or close other work.", error); }
        finally { if (bitmap != null) bitmap.recycle(); }
    }
    public static PhotoDocument.Pixels pixels(Bitmap bitmap) throws IOException {
        PhotoDocument.validateSize(bitmap.getWidth(), bitmap.getHeight());
        try { ByteArrayOutputStream output = new ByteArrayOutputStream(); if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) throw new IOException("Unable to encode layer pixels."); return new PhotoDocument.Pixels(output.toByteArray()); }
        catch (OutOfMemoryError error) { throw new IOException("Insufficient memory to encode photo pixels. The current layer remains intact.", error); }
    }
    public static Bitmap decode(PhotoDocument.Pixels pixels) throws IOException {
        Bitmap result;
        try { byte[] png = pixels.png(); result = BitmapFactory.decodeByteArray(png, 0, png.length); }
        catch (OutOfMemoryError error) { throw new IOException("This device has insufficient memory to decode the layer image.", error); }
        if (result == null || result.getWidth() != pixels.width || result.getHeight() != pixels.height) { if (result != null) result.recycle(); throw new IOException("Saved photo pixels could not be decoded."); }
        return result;
    }
    /** Same saved layer operations drive a bounded preview or full-resolution image.
     * Caller owns the returned Bitmap. Full export must not silently use maxSide.
     */
    public static Bitmap render(PhotoDocument document, int maxSide, long memoryBudgetBytes) throws IOException {
        requireSupported(document);
        double factor = maxSide > 0 ? Math.min(1, maxSide / (double)Math.max(document.width, document.height)) : 1;
        int width = Math.max(1, (int)Math.round(document.width * factor)), height = Math.max(1, (int)Math.round(document.height * factor));
        long count = (long)width * height, layerCost = 0;
        for (PhotoDocument.Layer layer : document.layers) if (layer.visible && layer.opacity > 0)
            layerCost = Math.max(layerCost, (long)layer.pixels.width * layer.pixels.height * (layer.mask == null ? 4 : 20) + layer.pixels.byteCount() + (layer.mask == null ? 0 : layer.mask.byteCount()));
        long required = count * 32 + layerCost;
        if (count > Integer.MAX_VALUE / 4 || memoryBudgetBytes < required) throw new IOException("Photo rendering needs about " + ((required + 1048575) / 1048576) + " MB of working memory. Use a smaller preview or a device with more memory; the full document stays intact.");
        Bitmap transformed = null, result = null;
        try {
            float[] composed = new float[(int)count * 4]; int[] pixels = new int[(int)count];
            transformed = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888); Canvas canvas = new Canvas(transformed);
            Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
            for (int layerIndex = document.layers.size() - 1; layerIndex >= 0; layerIndex--) {
                PhotoDocument.Layer layer = document.layers.get(layerIndex); if (!layer.visible || layer.opacity <= 0) continue;
                Bitmap source = decode(layer.pixels), masked = null;
                try {
                    if (layer.mask != null) { masked = applyMask(source, layer.mask); source.recycle(); source = masked; masked = null; }
                    transformed.eraseColor(Color.TRANSPARENT); canvas.drawBitmap(source, transform(layer, document, factor), paint);
                    transformed.getPixels(pixels, 0, width, 0, 0, width, height);
                    for (int index = 0; index < pixels.length; index++) {
                        int color = pixels[index], offset = index * 4; float alpha = (float)((color >>> 24) / 255.0 * layer.opacity), inverse = 1 - alpha;
                        composed[offset] = LINEAR[(color >> 16) & 255] * alpha + composed[offset] * inverse;
                        composed[offset + 1] = LINEAR[(color >> 8) & 255] * alpha + composed[offset + 1] * inverse;
                        composed[offset + 2] = LINEAR[color & 255] * alpha + composed[offset + 2] * inverse;
                        composed[offset + 3] = alpha + composed[offset + 3] * inverse;
                    }
                } finally { source.recycle(); if (masked != null) masked.recycle(); }
            }
            for (int index = 0; index < pixels.length; index++) {
                int offset = index * 4; float alpha = composed[offset + 3];
                pixels[index] = alpha <= 0 ? Color.TRANSPARENT : Color.argb(Math.round(alpha * 255), encoded(composed[offset] / alpha), encoded(composed[offset + 1] / alpha), encoded(composed[offset + 2] / alpha));
            }
            result = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888); return result;
        } catch (OutOfMemoryError error) { if (result != null) result.recycle(); throw new IOException("The device could not allocate the requested photo render. Your document was not changed.", error); }
        finally { if (transformed != null) transformed.recycle(); }
    }
    private static int encoded(float value) { double clamped = Math.max(0, Math.min(1, value)); return (int)Math.round(255 * (clamped <= .0031308 ? clamped * 12.92 : 1.055 * Math.pow(clamped, 1 / 2.4) - .055)); }
    /** Convert the shared Y-up source transform to Android's Y-down Bitmap canvas once. */
    public static Matrix transform(PhotoDocument.Layer layer, PhotoDocument document, double factor) {
        float[] source = {0, 0, layer.pixels.width, 0, 0, layer.pixels.height}, target = new float[6];
        double[][] points = {layer.documentPoint(0, layer.pixels.height, document.width, document.height),
                layer.documentPoint(layer.pixels.width, layer.pixels.height, document.width, document.height), layer.documentPoint(0, 0, document.width, document.height)};
        for (int i = 0; i < points.length; i++) { target[i * 2] = (float)(points[i][0] * factor); target[i * 2 + 1] = (float)((document.height - points[i][1]) * factor); }
        Matrix result = new Matrix(); result.setPolyToPoly(source, 0, target, 0, 3); return result;
    }
    private static Bitmap applyMask(Bitmap source, PhotoDocument.Pixels encodedMask) throws IOException {
        Bitmap mask = decode(encodedMask), result = null, coverage = null;
        try {
            int width = source.getWidth(), height = source.getHeight(); int[] values = new int[width * height]; mask.getPixels(values, 0, width, 0, 0, width, height);
            for (int i = 0; i < values.length; i++) { int value = values[i]; float luminosity = .2126f * LINEAR[(value >> 16) & 255] + .7152f * LINEAR[(value >> 8) & 255] + .0722f * LINEAR[value & 255]; values[i] = Color.argb(Math.round(luminosity * (value >>> 24)), 255, 255, 255); }
            coverage = Bitmap.createBitmap(values, width, height, Bitmap.Config.ARGB_8888); result = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            Canvas canvas = new Canvas(result); Paint paint = new Paint(); canvas.drawBitmap(source, 0, 0, paint); paint.setXfermode(new PorterDuffXfermode(PorterDuff.Mode.DST_IN)); canvas.drawBitmap(coverage, 0, 0, paint); return result;
        } catch (OutOfMemoryError error) { if (result != null) result.recycle(); throw new IOException("Insufficient memory to apply this photo mask.", error); }
        finally { mask.recycle(); if (coverage != null) coverage.recycle(); }
    }
}
