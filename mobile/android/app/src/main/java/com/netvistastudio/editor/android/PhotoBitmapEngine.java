package com.netvistastudio.editor.android;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Matrix;
import android.graphics.Paint;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Iterator;
import java.util.List;
import org.json.JSONException;
import org.json.JSONObject;

/** Native, bounded linear-sRGB compositor for the shared layered photo format.
 * Folder isolation, adjustment masks, eight blends and basic colour operations
 * preserve the Mac document's structure/order; Canvas supplies native affine
 * resampling. Vendor-specific Core Image filters are still rejected explicitly:
 * this is not a claim that Android reproduces every Core Image filter kernel.
 */
public final class PhotoBitmapEngine {
    private static final float[] LINEAR = new float[256];
    static { for (int i = 0; i < LINEAR.length; i++) { double value = i / 255.0; LINEAR[i] = (float)(value <= .04045 ? value / 12.92 : Math.pow((value + .055) / 1.055, 2.4)); } }
    private PhotoBitmapEngine() {}

    public static List<String> unsupportedOperations(PhotoDocument document) throws IOException {
        List<String> result = new ArrayList<>();
        for (PhotoDocument.Layer layer : document.layers) {
            if (layer.pixels.bitDepth > 8 || layer.mask != null && layer.mask.bitDepth > 8) add(result, "16-bit PNG processing");
            try {
                JSONObject value = layer.properties(), a = value.getJSONObject("adjustments");
                List<String> knownLayer = Arrays.asList("id", "name", "sourcePath", "isVisible", "isLocked", "opacity", "blendMode", "positionX", "positionY", "scale", "rotation", "adjustments", "extras");
                Iterator<String> layerKeys = value.keys(); while (layerKeys.hasNext()) { String key = layerKeys.next(); if (!knownLayer.contains(key)) add(result, "Unrecognised layer field: " + key); }
                for (int i = 4; i < PhotoDocument.ADJUSTMENT_DEFAULTS.length; i++)
                    if (a.getDouble(PhotoDocument.ADJUSTMENT_KEYS[i]) != PhotoDocument.ADJUSTMENT_DEFAULTS[i]) add(result, "Adjustment: " + PhotoDocument.ADJUSTMENT_KEYS[i]);
                Iterator<String> keys = a.keys(); while (keys.hasNext()) { String key = keys.next(); if (!Arrays.asList(PhotoDocument.ADJUSTMENT_KEYS).contains(key)) add(result, "Unrecognised adjustment: " + key); }
                JSONObject e = value.optJSONObject("extras");
                if (e != null) {
                    for (String key : new String[]{"hue", "midtone", "curveShadows", "curveHighlights", "noise"})
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
            layerCost = Math.max(layerCost, (long)layer.pixels.width * layer.pixels.height * 28 + layer.pixels.byteCount() + (layer.mask == null ? 0 : layer.mask.byteCount()));
        // At most root + one isolated folder + a mirrored adjustment snapshot
        // coexist. Include their float buffers, Bitmap/int staging and result.
        // Reserve conservatively before decoding any source or publishing pixels.
        long required = count * 64 + layerCost;
        if (count > Integer.MAX_VALUE / 4 || memoryBudgetBytes < required) throw new IOException("Photo rendering needs about " + ((required + 1048575) / 1048576) + " MB of working memory. Use a smaller preview or a device with more memory; the full document stays intact.");
        Compositor compositor = null; Bitmap result = null;
        try {
            compositor = new Compositor(document, width, height, factor);
            float[] composed = compositor.level(null); int[] pixels = compositor.pixels;
            for (int index = 0; index < pixels.length; index++) {
                int offset = index * 4; float alpha = composed[offset + 3];
                pixels[index] = alpha <= 0 ? Color.TRANSPARENT : Color.argb(Math.round(alpha * 255), encoded(composed[offset] / alpha), encoded(composed[offset + 1] / alpha), encoded(composed[offset + 2] / alpha));
            }
            result = Bitmap.createBitmap(pixels, width, height, Bitmap.Config.ARGB_8888); return result;
        } catch (OutOfMemoryError error) { if (result != null) result.recycle(); throw new IOException("The device could not allocate the requested photo render. Your document was not changed.", error); }
        finally { if (compositor != null) compositor.transformed.recycle(); }
    }

    private static final class Grade {
        final float exposure, brightness, contrast, saturation, gain, bias;
        final boolean mirrored;
        Grade(PhotoDocument.Layer layer) throws IOException {
            try {
                JSONObject record = layer.properties(), a = record.getJSONObject("adjustments"), e = record.optJSONObject("extras");
                exposure = (float)Math.pow(2, a.getDouble("exposure")); brightness = (float)a.getDouble("brightness");
                contrast = (float)a.getDouble("contrast"); saturation = (float)a.getDouble("saturation"); mirrored = a.getBoolean("mirrored");
                double black = e == null ? 0 : e.optDouble("black", 0), white = e == null ? 1 : e.optDouble("white", 1);
                gain = (float)(1 / Math.max(.01, white - black)); bias = (float)(-black * gain);
            } catch (JSONException error) { throw PhotoDocument.invalid("Invalid colour settings", error); }
        }
        void apply(float[] rgb) {
            float red = rgb[0] * exposure, green = rgb[1] * exposure, blue = rgb[2] * exposure;
            float luma = .2126f * red + .7152f * green + .0722f * blue;
            // Work in unassociated linear sRGB. Do not clip intermediate values
            // to 8 bits: a later adjustment can recover exposure/contrast range.
            rgb[0] = ((luma + saturation * (red - luma) - .5f) * contrast + .5f + brightness) * gain + bias;
            rgb[1] = ((luma + saturation * (green - luma) - .5f) * contrast + .5f + brightness) * gain + bias;
            rgb[2] = ((luma + saturation * (blue - luma) - .5f) * contrast + .5f + brightness) * gain + bias;
        }
    }

    private static final class Compositor {
        final PhotoDocument document;
        final int width, height;
        final double factor;
        final int[] pixels;
        final Bitmap transformed;
        final Canvas canvas;
        final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG | Paint.FILTER_BITMAP_FLAG);
        Compositor(PhotoDocument document, int width, int height, double factor) {
            this.document = document; this.width = width; this.height = height; this.factor = factor;
            pixels = new int[width * height]; transformed = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
            try { canvas = new Canvas(transformed); }
            catch (OutOfMemoryError error) { transformed.recycle(); throw error; }
        }
        float[] level(String parent) throws IOException {
            float[] result = new float[width * height * 4]; float[] rgb = new float[3];
            for (int i = document.layers.size() - 1; i >= 0; i--) {
                PhotoDocument.Layer layer = document.layers.get(i);
                if (!layer.visible || layer.opacity <= 0 || !sameParent(parent, layer.groupId)) continue;
                Grade grade = new Grade(layer);
                if (layer.adjustment) { adjust(result, layer, grade, rgb); continue; }
                if (layer.group) {
                    float[] children = level(layer.id);
                    if (grade.mirrored) mirror(children);
                    for (int p = 0; p < pixels.length; p++) {
                        int offset = p * 4; float alpha = children[offset + 3];
                        if (alpha <= 0) continue;
                        rgb[0] = children[offset] / alpha; rgb[1] = children[offset + 1] / alpha; rgb[2] = children[offset + 2] / alpha;
                        grade.apply(rgb); blend(result, offset, rgb, (float)(alpha * layer.opacity), layer.blendMode);
                    }
                    children = null; // Do not retain the prior folder while allocating the next one.
                    continue;
                }
                Bitmap source = prepareRaster(layer, grade.mirrored);
                try {
                    transformed.eraseColor(Color.TRANSPARENT); canvas.drawBitmap(source, transform(layer, document, factor), paint);
                    transformed.getPixels(pixels, 0, width, 0, 0, width, height);
                    for (int p = 0; p < pixels.length; p++) {
                        int color = pixels[p]; float alpha = (float)((color >>> 24) / 255.0 * layer.opacity);
                        if (alpha <= 0) continue;
                        rgb[0] = LINEAR[(color >> 16) & 255]; rgb[1] = LINEAR[(color >> 8) & 255]; rgb[2] = LINEAR[color & 255];
                        grade.apply(rgb); blend(result, p * 4, rgb, alpha, layer.blendMode);
                    }
                } finally { source.recycle(); }
            }
            return result;
        }
        void adjust(float[] result, PhotoDocument.Layer layer, Grade grade, float[] rgb) throws IOException {
            // Adjustment placement/scale are intentionally ignored, matching the
            // saved Mac compositor: its mask is fixed in document coordinates.
            if (layer.mask != null) {
                Bitmap mask = decode(layer.mask);
                try {
                    transformed.eraseColor(Color.TRANSPARENT); Matrix placement = new Matrix();
                    placement.setValues(new float[]{(float)factor, 0, 0, 0, (float)factor, (float)((document.height - mask.getHeight()) * factor), 0, 0, 1});
                    canvas.drawBitmap(mask, placement, paint); transformed.getPixels(pixels, 0, width, 0, 0, width, height);
                } finally { mask.recycle(); }
            }
            float[] source = grade.mirrored ? result.clone() : result;
            for (int p = 0; p < pixels.length; p++) {
                float amount = (float)layer.opacity * (layer.mask == null ? 1 : maskCoverage(pixels[p]));
                if (amount <= 0) continue;
                int offset = p * 4, from = grade.mirrored ? ((p / width) * width + width - 1 - p % width) * 4 : offset;
                float alpha = source[from + 3];
                rgb[0] = alpha > 0 ? source[from] / alpha : 0; rgb[1] = alpha > 0 ? source[from + 1] / alpha : 0; rgb[2] = alpha > 0 ? source[from + 2] / alpha : 0;
                grade.apply(rgb);
                float oldR = result[offset], oldG = result[offset + 1], oldB = result[offset + 2], oldA = result[offset + 3];
                if (layer.blendMode.equals("Normal")) {
                    result[offset] = rgb[0] * alpha; result[offset + 1] = rgb[1] * alpha; result[offset + 2] = rgb[2] * alpha; result[offset + 3] = alpha;
                } else blend(result, offset, rgb, alpha, layer.blendMode);
                result[offset] = oldR + (result[offset] - oldR) * amount; result[offset + 1] = oldG + (result[offset + 1] - oldG) * amount;
                result[offset + 2] = oldB + (result[offset + 2] - oldB) * amount; result[offset + 3] = oldA + (result[offset + 3] - oldA) * amount;
            }
        }
        void mirror(float[] pixels) {
            for (int y = 0; y < height; y++) for (int x = 0; x < width / 2; x++) {
                int left = (y * width + x) * 4, right = (y * width + width - 1 - x) * 4;
                for (int channel = 0; channel < 4; channel++) { float value = pixels[left + channel]; pixels[left + channel] = pixels[right + channel]; pixels[right + channel] = value; }
            }
        }
    }

    private static boolean sameParent(String first, String second) { return first == null ? second == null : second != null && first.equalsIgnoreCase(second); }
    private static float maskCoverage(int color) {
        return ((color >>> 24) / 255f) * (.2126f * LINEAR[(color >> 16) & 255] + .7152f * LINEAR[(color >> 8) & 255] + .0722f * LINEAR[color & 255]);
    }
    private static void blend(float[] background, int offset, float[] rgb, float alpha, String mode) {
        float backAlpha = background[offset + 3], inverse = 1 - alpha;
        for (int channel = 0; channel < 3; channel++) {
            float back = backAlpha > 0 ? background[offset + channel] / backAlpha : 0, front = rgb[channel];
            float mixed = mode.equals("Normal") ? front : blendChannel(back, front, mode);
            background[offset + channel] = background[offset + channel] * inverse + front * alpha * (1 - backAlpha) + mixed * alpha * backAlpha;
        }
        background[offset + 3] = alpha + backAlpha * inverse;
    }
    private static float blendChannel(float back, float front, String mode) {
        float b = Math.max(0, Math.min(1, back)), s = Math.max(0, Math.min(1, front));
        switch (mode) {
            case "Multiply": return b * s;
            case "Screen": return b + s - b * s;
            case "Overlay": return b <= .5f ? 2 * b * s : 1 - 2 * (1 - b) * (1 - s);
            case "Soft Light":
                if (s <= .5f) return b - (1 - 2 * s) * b * (1 - b);
                float curve = b <= .25f ? ((16 * b - 12) * b + 4) * b : (float)Math.sqrt(b);
                return b + (2 * s - 1) * (curve - b);
            case "Darken": return Math.min(b, s);
            case "Lighten": return Math.max(b, s);
            case "Color Dodge": return b <= 0 ? 0 : s >= 1 ? 1 : Math.min(1, b / (1 - s));
            default: throw new IllegalArgumentException("Unknown photo blend mode: " + mode);
        }
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
    private static Bitmap prepareRaster(PhotoDocument.Layer layer, boolean mirrored) throws IOException {
        Bitmap source = decode(layer.pixels);
        if (!mirrored && layer.mask == null) return source;
        Bitmap mask = null, result = null;
        try {
            int width = source.getWidth(), height = source.getHeight(); int[] colors = new int[width * height]; source.getPixels(colors, 0, width, 0, 0, width, height);
            if (mirrored) for (int y = 0; y < height; y++) for (int x = 0; x < width / 2; x++) {
                int left = y * width + x, right = y * width + width - 1 - x, color = colors[left]; colors[left] = colors[right]; colors[right] = color;
            }
            // Masks follow the already-mirrored pixels, not the original image
            // coordinates. Mirroring a layer must not also mirror its mask.
            if (layer.mask != null) {
                mask = decode(layer.mask); int[] values = new int[width * height]; mask.getPixels(values, 0, width, 0, 0, width, height);
                for (int i = 0; i < values.length; i++) colors[i] = (colors[i] & 0x00ffffff) | (Math.round((colors[i] >>> 24) * maskCoverage(values[i])) << 24);
            }
            result = Bitmap.createBitmap(colors, width, height, Bitmap.Config.ARGB_8888); return result;
        } catch (OutOfMemoryError error) { if (result != null) result.recycle(); throw new IOException("Insufficient memory to mirror or mask this photo layer.", error); }
        finally { source.recycle(); if (mask != null) mask.recycle(); }
    }
}
