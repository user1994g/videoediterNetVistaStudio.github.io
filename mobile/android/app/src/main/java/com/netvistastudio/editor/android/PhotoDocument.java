package com.netvistastudio.editor.android;

import android.util.Base64;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.zip.CRC32;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Immutable, lossless adapter for the existing Mac/UIKit .netvistaphoto v2 schema.
 * Layers remain topmost first. PNG bytes and unrecognised JSON properties survive
 * metadata edits; renderer support is a separate contract, never a flattening step.
 */
public final class PhotoDocument {
    public static final int MAX_PROJECT_BYTES = 512 * 1024 * 1024;
    public static final long MAX_PIXELS = 64_000_000L;
    public static final int MAX_EDGE = 16000, MAX_LAYERS = 1024;
    static final String FORMAT = "NetVista Photo Project";
    static final String[] ADJUSTMENT_KEYS = {"exposure", "brightness", "contrast", "saturation", "vibrance",
            "highlights", "shadows", "temperature", "tint", "sharpen", "blur", "sepia", "vignette", "mirrored"};
    static final double[] ADJUSTMENT_DEFAULTS = {0, 0, 1, 1, 0, 1, 0, 6500, 0, 0, 0, 0, 0};
    static final Set<String> BLEND_MODES = Collections.unmodifiableSet(new HashSet<>(Arrays.asList("Normal", "Multiply", "Screen", "Overlay", "Soft Light", "Darken", "Lighten", "Color Dodge")));
    public final int width, height;
    public final double dpi;
    public final String selectedLayerId;
    public final List<Layer> layers;
    private final String headerJSON;

    /** Immutable compressed pixels. Metadata-only history shares this allocation. */
    public static final class Pixels {
        public final int width, height, bitDepth;
        private final byte[] png;
        public Pixels(byte[] png) throws IOException {
            if (png == null || png.length > MAX_PROJECT_BYTES) throw new IOException("Layer PNG is missing or exceeds 512 MB.");
            try { this.png = png.clone(); } catch (OutOfMemoryError error) { throw new IOException("Insufficient memory to retain immutable layer pixels.", error); }
            int[] size = pngSize(this.png); width = size[0]; height = size[1]; bitDepth = size[2];
        }
        public byte[] png() { return png.clone(); }
        public int byteCount() { return png.length; }
        String encodedBase64() { return Base64.encodeToString(png, Base64.NO_WRAP); }
    }

    public static final class Layer {
        public final String id, name;
        public final Pixels pixels, mask;
        public final boolean visible, locked, group, adjustment;
        public final double opacity, positionX, positionY, scale, rotation, skew;
        public final String blendMode, groupId;
        private final String metadataJSON;
        private Layer(JSONObject record, Pixels pixels, Pixels mask) throws IOException {
            try {
                id = uuid(string(record, "id")); name = text(string(record, "name"), "Layer name", 4096);
                string(record, "sourcePath");
                visible = bool(record, "isVisible"); locked = bool(record, "isLocked");
                opacity = number(record, "opacity", 0, 1); positionX = number(record, "positionX", -1_000_000, 1_000_000);
                positionY = number(record, "positionY", -1_000_000, 1_000_000);
                scale = number(record, "scale", Double.MIN_VALUE, 100); rotation = number(record, "rotation", -360_000, 360_000);
                blendMode = string(record, "blendMode");
                if (!BLEND_MODES.contains(blendMode)) throw new IOException("Unknown layer blend mode: " + blendMode);
                JSONObject a = record.getJSONObject("adjustments");
                double[][] ranges = {{-20,20},{-2,2},{0,10},{0,10},{-2,2},{0,4},{-4,4},{1000,40000},{-1000,1000},{0,10},{0,500},{0,1},{0,10}};
                for (int i = 0; i < ADJUSTMENT_DEFAULTS.length; i++) number(a, ADJUSTMENT_KEYS[i], ranges[i][0], ranges[i][1]);
                bool(a, "mirrored");
                JSONObject e = record.optJSONObject("extras");
                if (record.has("extras") && !record.isNull("extras") && e == null) throw new IOException("Invalid layer extras.");
                if (e != null) for (String key : new String[]{"isGroup", "isAdjustment", "skew", "hue", "black", "white", "midtone", "curveShadows", "curveHighlights", "noise"})
                    if (e.has(key) && e.isNull(key)) throw new IOException("Invalid null layer property: " + key);
                group = optionalBool(e, "isGroup", false); adjustment = optionalBool(e, "isAdjustment", false);
                if (group && adjustment) throw new IOException("A layer cannot be both a folder and an adjustment.");
                groupId = e == null || !e.has("groupID") || e.isNull("groupID") ? null : uuid(string(e, "groupID"));
                skew = optionalNumber(e, "skew", 0, -10, 10);
                optionalNumber(e, "hue", 0, -360, 360);
                for (String key : new String[]{"black", "white", "midtone", "curveShadows", "curveHighlights", "noise"})
                    optionalNumber(e, key, extraDefault(key), 0, 1);
                if (e != null) {
                    if (e.has("text") && !e.isNull("text")) string(e, "text");
                    if (e.has("fontName") && !e.isNull("fontName")) string(e, "fontName");
                    if (e.has("fontSize") && !e.isNull("fontSize")) number(e, "fontSize", 1, 2000);
                    if (e.has("textColor") && !e.isNull("textColor")) {
                        JSONArray color = e.getJSONArray("textColor");
                        if (color.length() != 4) throw new IOException("Text colour needs four components.");
                        for (int i = 0; i < 4; i++) finiteRange(color.get(i), "Text colour", 0, 1);
                    }
                }
                if (pixels == null) throw new IOException("Layer ‘" + name + "’ needs embedded pixels. Relink legacy source files on Mac/iPad first.");
                if (mask != null && (mask.width != pixels.width || mask.height != pixels.height)) throw new IOException("Layer mask dimensions do not match its image.");
                this.pixels = pixels; this.mask = mask;
                JSONObject metadata = copyWithout(record, "pixels");
                if (e != null) { JSONObject extraCopy = copyWithout(e, "maskPNG"); fillExtraDefaults(extraCopy); metadata.put("extras", extraCopy); }
                metadataJSON = metadata.toString();
            } catch (JSONException | IllegalArgumentException error) { throw invalid("Invalid photo layer", error); }
        }
        public JSONObject properties() throws IOException { return json(metadataJSON); }
        JSONObject encoded() throws IOException {
            try {
                JSONObject value = properties(); value.put("pixels", pixels.encodedBase64());
                if (mask != null) {
                    JSONObject e = extras(value);
                    e.put("maskPNG", mask.encodedBase64());
                }
                return value;
            } catch (JSONException error) { throw invalid("Cannot encode photo layer", error); }
        }
        /** Return a validated independent metadata edit; callers never receive a live mutable layer. */
        public Layer withProperty(String key, Object value) throws IOException {
            if (!Arrays.asList("name", "isVisible", "isLocked", "opacity", "blendMode", "positionX", "positionY", "scale", "rotation").contains(key))
                throw new IOException("Use a typed pixel, adjustment or folder command for this property.");
            try { JSONObject candidate = properties(); candidate.put(key, value); return new Layer(candidate, pixels, mask); }
            catch (JSONException error) { throw invalid("Invalid layer property", error); }
        }
        public Layer withPixels(Pixels value) throws IOException { return new Layer(properties(), value, mask); }
        public Layer withMask(Pixels value) throws IOException { return new Layer(properties(), pixels, value); }
        public Layer withAdjustment(String key, double value) throws IOException {
            if (!Arrays.asList(ADJUSTMENT_KEYS).contains(key) || key.equals("mirrored")) throw new IOException("Unknown numeric photo adjustment.");
            try { JSONObject candidate = properties(); candidate.getJSONObject("adjustments").put(key, value); return new Layer(candidate, pixels, mask); }
            catch (JSONException error) { throw invalid("Invalid adjustment", error); }
        }
        Layer duplicate(String newId, String parent) throws IOException {
            try {
                JSONObject candidate = properties(); candidate.put("id", newId); candidate.put("name", name + " copy");
                if (parent != null) { JSONObject e = extras(candidate); e.put("groupID", parent); }
                return new Layer(candidate, pixels, mask);
            } catch (JSONException error) { throw invalid("Cannot duplicate layer", error); }
        }
        public Layer inGroup(String parent) throws IOException {
            try { JSONObject candidate = properties(); JSONObject e = extras(candidate); if (parent == null) e.remove("groupID"); else e.put("groupID", uuid(parent)); return new Layer(candidate, pixels, mask); }
            catch (JSONException error) { throw invalid("Invalid folder", error); }
        }
        /** Source coordinates and document coordinates both use positive Y upward. */
        public double[] documentPoint(double x, double y, int canvasWidth, int canvasHeight) {
            double localX = (x - pixels.width / 2.0) * scale + (y - pixels.height / 2.0) * skew * scale;
            double localY = (y - pixels.height / 2.0) * scale, angle = Math.toRadians(rotation);
            return new double[]{localX * Math.cos(angle) - localY * Math.sin(angle) + canvasWidth / 2.0 + positionX,
                    localX * Math.sin(angle) + localY * Math.cos(angle) + canvasHeight / 2.0 + positionY};
        }
        public double[] sourcePoint(double x, double y, int canvasWidth, int canvasHeight) {
            double localX = x - canvasWidth / 2.0 - positionX, localY = y - canvasHeight / 2.0 - positionY, angle = Math.toRadians(rotation);
            double unrotatedX = localX * Math.cos(angle) + localY * Math.sin(angle);
            double unrotatedY = -localX * Math.sin(angle) + localY * Math.cos(angle);
            return new double[]{(unrotatedX - skew * unrotatedY) / scale + pixels.width / 2.0, unrotatedY / scale + pixels.height / 2.0};
        }
        boolean same(Layer other) { return pixels == other.pixels && mask == other.mask && metadataJSON.equals(other.metadataJSON); }
        long encodedSize() { return metadataJSON.getBytes(StandardCharsets.UTF_8).length + 32L + 4L * ((pixels.byteCount() + 2L) / 3) + (mask == null ? 0 : 4L * ((mask.byteCount() + 2L) / 3) + 32); }
    }

    private PhotoDocument(JSONObject header, List<Layer> layers, String selected) throws IOException {
        try {
            width = dimension(header.get("canvasWidth")); height = dimension(header.get("canvasHeight")); validateSize(width, height);
            dpi = optionalNumber(header, "dpi", 72, 1, 1200);
            if (!FORMAT.equals(string(header, "format")) || integer(header.get("version")) != 2) throw new IOException("Unsupported NetVista photo project version.");
            if (layers.size() > MAX_LAYERS) throw new IOException("Photo project exceeds 1,024 layers.");
            Set<String> identifiers = new HashSet<>(); Map<String, Layer> lookup = new HashMap<>();
            for (Layer layer : layers) {
                if (layer == null || !identifiers.add(idKey(layer.id))) throw new IOException("Duplicate or missing photo layer identifier.");
                lookup.put(idKey(layer.id), layer);
            }
            for (Layer layer : layers) if (layer.groupId != null) {
                Layer parent = lookup.get(idKey(layer.groupId));
                if (layer.group || parent == null || !parent.group || parent.groupId != null) throw new IOException("Invalid photo folder reference. Nested folders are not supported by the saved schema.");
            }
            this.layers = Collections.unmodifiableList(new ArrayList<>(layers));
            if (selected != null && !identifiers.contains(idKey(uuid(selected)))) throw new IOException("Selected layer is not in this photo document.");
            selectedLayerId = selected == null ? null : lookup.get(idKey(selected)).id;
            JSONObject clean = copyWithout(header, "layers", "selectedLayerID"); headerJSON = clean.toString();
            long size = headerJSON.getBytes(StandardCharsets.UTF_8).length + 128L;
            for (Layer layer : layers) size += layer.encodedSize();
            if (size > MAX_PROJECT_BYTES) throw new IOException("Photo project exceeds the 512 MB save budget.");
        } catch (JSONException | IllegalArgumentException error) { throw invalid("Invalid photo document", error); }
    }
    public static PhotoDocument decode(String source) throws IOException {
        Runtime runtime = Runtime.getRuntime(); long available = runtime.maxMemory() - (runtime.totalMemory() - runtime.freeMemory());
        return decode(source, Math.max(1, available / 2));
    }
    /** The format permits 512 MB; a non-streaming caller must also have enough
     * heap for its JSON strings/base64 staging. Reject before parsing otherwise.
     */
    public static PhotoDocument decode(String source, long workingMemoryBudget) throws IOException {
        if (source == null) throw new IOException("Photo project is missing.");
        if ((long)source.length() * 6 > workingMemoryBudget) throw new IOException("This device has insufficient working memory to open this embedded photo project. The current edit remains intact.");
        try { return decodeChecked(source); }
        catch (OutOfMemoryError error) { throw new IOException("The device could not allocate this photo document. The current edit remains intact.", error); }
    }
    private static PhotoDocument decodeChecked(String source) throws IOException {
        if (source == null || source.length() > MAX_PROJECT_BYTES || source.getBytes(StandardCharsets.UTF_8).length > MAX_PROJECT_BYTES) throw new IOException("Photo project exceeds 512 MB.");
        try {
            JSONObject value = json(source);
            if (FORMAT.equals(value.optString("format")) && value.optInt("version") == 1) throw new IOException("This legacy photo project uses linked images. Save an embedded v2 project on Mac/iPad before opening it here.");
            JSONArray records = value.getJSONArray("layers"); if (records.length() > MAX_LAYERS) throw new IOException("Photo project exceeds 1,024 layers.");
            List<Layer> layers = new ArrayList<>();
            for (int i = 0; i < records.length(); i++) {
                JSONObject record = records.getJSONObject(i); Pixels pixels = decodePNG(record, "pixels");
                JSONObject extras = record.optJSONObject("extras"); Pixels mask = extras == null ? null : decodePNG(extras, "maskPNG");
                layers.add(new Layer(record, pixels, mask));
            }
            String selected = value.has("selectedLayerID") && !value.isNull("selectedLayerID") ? string(value, "selectedLayerID") : null;
            if (selected != null) uuid(selected);
            boolean exists = false; for (Layer layer : layers) if (selected != null && layer.id.equalsIgnoreCase(selected)) exists = true;
            if (!exists) selected = layers.isEmpty() ? null : layers.get(0).id;
            return new PhotoDocument(value, layers, selected);
        } catch (JSONException | IllegalArgumentException error) { throw invalid("Invalid NetVista photo project", error); }
    }
    public String encode() throws IOException {
        try { return encodeChecked(); }
        catch (OutOfMemoryError error) { throw new IOException("The device could not allocate the embedded photo save. Keep the current edit and try again with more memory available.", error); }
    }
    private String encodeChecked() throws IOException {
        try {
            JSONObject value = json(headerJSON); JSONArray records = new JSONArray();
            for (Layer layer : layers) records.put(layer.encoded()); value.put("layers", records);
            if (selectedLayerId != null) value.put("selectedLayerID", selectedLayerId);
            String result = value.toString();
            if (result.length() > MAX_PROJECT_BYTES || result.getBytes(StandardCharsets.UTF_8).length > MAX_PROJECT_BYTES) throw new IOException("Photo project exceeds 512 MB.");
            return result;
        } catch (JSONException error) { throw invalid("Cannot encode photo document", error); }
    }
    public static PhotoDocument blank(int width, int height, double dpi, Pixels pixels, String name) throws IOException {
        validateSize(width, height);
        if (pixels == null) throw new IOException("Background pixels are missing.");
        if (pixels.width != width || pixels.height != height) throw new IOException("Background pixels must match the canvas.");
        try {
            JSONObject header = new JSONObject(); header.put("format", FORMAT); header.put("version", 2); header.put("canvasWidth", width); header.put("canvasHeight", height); header.put("dpi", dpi);
            Layer layer = raster(name, pixels);
            return new PhotoDocument(header, Collections.singletonList(layer), layer.id);
        } catch (JSONException error) { throw invalid("Cannot create document", error); }
    }
    public static Layer raster(String name, Pixels pixels) throws IOException {
        try {
            JSONObject record = new JSONObject(); record.put("id", UUID.randomUUID().toString()); record.put("name", name); record.put("sourcePath", "");
            record.put("isVisible", true); record.put("isLocked", false); record.put("opacity", 1); record.put("blendMode", "Normal");
            record.put("positionX", 0); record.put("positionY", 0); record.put("scale", 1); record.put("rotation", 0);
            JSONObject adjustments = new JSONObject(); for (int i = 0; i < ADJUSTMENT_DEFAULTS.length; i++) adjustments.put(ADJUSTMENT_KEYS[i], ADJUSTMENT_DEFAULTS[i]); adjustments.put("mirrored", false); record.put("adjustments", adjustments);
            return new Layer(record, pixels, null);
        } catch (JSONException error) { throw invalid("Cannot create layer", error); }
    }
    public static Layer folder(String name, Pixels transparentPixel) throws IOException {
        if (transparentPixel.width != 1 || transparentPixel.height != 1) throw new IOException("Folder storage uses one transparent pixel.");
        try { Layer layer = raster(name, transparentPixel); JSONObject value = layer.properties(); extras(value).put("isGroup", true); return new Layer(value, transparentPixel, null); }
        catch (JSONException error) { throw invalid("Cannot create folder", error); }
    }
    public Layer layer(String id) { if (id == null) return null; for (Layer layer : layers) if (idKey(layer.id).equals(idKey(id))) return layer; return null; }
    public PhotoDocument withLayers(List<Layer> next, String selected) throws IOException {
        if (next == null) throw new IOException("Photo layers are missing.");
        boolean exists = false; for (Layer layer : next) { if (layer == null) throw new IOException("Photo layer is missing."); if (selected != null && layer.id.equalsIgnoreCase(selected)) exists = true; }
        if (selected != null && !exists) selected = next.isEmpty() ? null : next.get(0).id;
        return new PhotoDocument(json(headerJSON), next, selected);
    }
    public PhotoDocument selecting(String id) throws IOException { PhotoDocument.Layer selected = layer(id); return new PhotoDocument(json(headerJSON), layers, selected == null ? null : selected.id); }
    boolean same(PhotoDocument other) {
        if (!headerJSON.equals(other.headerJSON) || !java.util.Objects.equals(selectedLayerId, other.selectedLayerId) || layers.size() != other.layers.size()) return false;
        for (int i = 0; i < layers.size(); i++) if (!layers.get(i).same(other.layers.get(i))) return false; return true;
    }
    static String idKey(String id) { return id.toLowerCase(java.util.Locale.ROOT); }
    static JSONObject json(String text) throws IOException { try { return new JSONObject(text); } catch (JSONException error) { throw invalid("Invalid photo JSON", error); } }
    private static JSONObject copyWithout(JSONObject source, String... excluded) throws JSONException {
        JSONObject result = new JSONObject(); java.util.Iterator<String> keys = source.keys();
        while (keys.hasNext()) { String key = keys.next(); if (!Arrays.asList(excluded).contains(key)) result.put(key, source.get(key)); } return result;
    }
    private static JSONObject extras(JSONObject record) throws JSONException {
        JSONObject value = record.optJSONObject("extras"); if (value == null) { value = new JSONObject(); record.put("extras", value); } fillExtraDefaults(value); return value;
    }
    /** Swift's synthesized Codable requires every non-optional extras field. */
    private static void fillExtraDefaults(JSONObject extras) throws JSONException {
        if (!extras.has("isGroup")) extras.put("isGroup", false); if (!extras.has("isAdjustment")) extras.put("isAdjustment", false);
        for (String key : new String[]{"skew", "hue", "black", "white", "midtone", "curveShadows", "curveHighlights", "noise"}) if (!extras.has(key)) extras.put(key, extraDefault(key));
    }
    private static Pixels decodePNG(JSONObject record, String key) throws IOException, JSONException {
        if (!record.has(key) || record.isNull(key)) return null;
        String encoded = string(record, key);
        if (encoded.length() > (long) MAX_PROJECT_BYTES * 4 / 3 + 8) throw new IOException("Embedded photo pixels exceed 512 MB.");
        try { return new Pixels(Base64.decode(encoded, Base64.DEFAULT)); }
        catch (IllegalArgumentException error) { throw invalid("Invalid embedded photo pixels", error); }
    }
    private static String uuid(String value) throws IOException {
        try { if (!UUID.fromString(value).toString().equalsIgnoreCase(value)) throw new IllegalArgumentException(); return value; }
        catch (IllegalArgumentException error) { throw invalid("Invalid layer identifier", error); }
    }
    private static String text(String value, String label, int maximum) throws IOException { if (value.isEmpty() || value.getBytes(StandardCharsets.UTF_8).length > maximum) throw new IOException(label + " is empty or too long."); return value; }
    static String string(JSONObject value, String key) throws IOException, JSONException { Object item = value.get(key); if (!(item instanceof String)) throw new IOException("Invalid string photo property: " + key); return (String) item; }
    static boolean bool(JSONObject value, String key) throws IOException, JSONException { Object item = value.get(key); if (!(item instanceof Boolean)) throw new IOException("Invalid boolean: " + key); return (Boolean) item; }
    static double number(JSONObject value, String key, double minimum, double maximum) throws IOException, JSONException { return finiteRange(value.get(key), key, minimum, maximum); }
    static double optionalNumber(JSONObject value, String key, double fallback, double minimum, double maximum) throws IOException, JSONException { return value == null || !value.has(key) || value.isNull(key) ? fallback : number(value, key, minimum, maximum); }
    private static boolean optionalBool(JSONObject value, String key, boolean fallback) throws IOException, JSONException { return value == null || !value.has(key) || value.isNull(key) ? fallback : bool(value, key); }
    private static double finiteRange(Object value, String key, double minimum, double maximum) throws IOException {
        if (!(value instanceof Number)) throw new IOException("Invalid numeric photo property: " + key);
        double result = ((Number) value).doubleValue(); if (!Double.isFinite(result) || result < minimum || result > maximum) throw new IOException("Photo property is out of range: " + key); return result;
    }
    private static long integer(Object value) throws IOException { double number = finiteRange(value, "Whole number", 0, Integer.MAX_VALUE); if (Math.floor(number) != number) throw new IOException("Expected whole-pixel value."); return (long) number; }
    private static int dimension(Object value) throws IOException { long number = integer(value); if (number < 1 || number > MAX_EDGE) throw new IOException("Invalid photo canvas dimensions."); return (int) number; }
    static void validateSize(int width, int height) throws IOException { if (width < 1 || height < 1 || width > MAX_EDGE || height > MAX_EDGE || (long) width * height > MAX_PIXELS) throw new IOException("Use a photo canvas up to 16,000 pixels per side and 64 megapixels."); }
    static double extraDefault(String key) { return key.equals("white") ? 1 : key.equals("midtone") ? .5 : key.equals("curveShadows") ? .25 : key.equals("curveHighlights") ? .75 : 0; }
    static IOException invalid(String message, Exception error) { return new IOException(message + ": " + error.getMessage(), error); }
    private static int[] pngSize(byte[] bytes) throws IOException {
        byte[] signature = {(byte)137,80,78,71,13,10,26,10};
        if (bytes.length < 45) throw new IOException("Truncated PNG image.");
        for (int i = 0; i < signature.length; i++) if (bytes[i] != signature[i]) throw new IOException("Embedded photo pixels must be PNG.");
        int offset = 8, width = 0, height = 0; boolean data = false, ended = false;
        while (offset < bytes.length) {
            if (bytes.length - offset < 12) throw new IOException("Truncated PNG chunk.");
            long length = unsignedInt(bytes, offset); if (length > bytes.length - offset - 12) throw new IOException("Truncated PNG chunk data.");
            int count = (int) length; String type = new String(bytes, offset + 4, 4, StandardCharsets.US_ASCII);
            CRC32 crc = new CRC32(); crc.update(bytes, offset + 4, count + 4);
            if (crc.getValue() != unsignedInt(bytes, offset + 8 + count)) throw new IOException("Damaged PNG checksum.");
            if (offset == 8) {
                if (!type.equals("IHDR") || count != 13) throw new IOException("PNG header is missing.");
                long w = unsignedInt(bytes, offset + 8), h = unsignedInt(bytes, offset + 12);
                if (w > MAX_EDGE || h > MAX_EDGE) throw new IOException("PNG image exceeds 16,000 pixels per side.");
                width = (int) w; height = (int) h; validateSize(width, height);
                int depth = bytes[24] & 255, color = bytes[25] & 255;
                boolean validDepth = color == 0 ? Arrays.asList(1,2,4,8,16).contains(depth) : color == 3 ? Arrays.asList(1,2,4,8).contains(depth) : (color == 2 || color == 4 || color == 6) && (depth == 8 || depth == 16);
                if (!validDepth || bytes[26] != 0 || bytes[27] != 0 || (bytes[28] & 255) > 1) throw new IOException("Invalid PNG encoding header.");
            } else if (type.equals("IHDR")) throw new IOException("Repeated PNG header.");
            if (type.equals("IDAT")) data = true;
            if (type.equals("IEND")) { if (count != 0 || !data || offset + 12 != bytes.length) throw new IOException("Invalid PNG end marker."); ended = true; }
            offset += count + 12;
        }
        if (!ended) throw new IOException("PNG image has no complete pixel stream."); return new int[]{width, height, bytes[24] & 255};
    }
    private static long unsignedInt(byte[] bytes, int offset) { return ((long)(bytes[offset] & 255) << 24) | ((long)(bytes[offset + 1] & 255) << 16) | ((long)(bytes[offset + 2] & 255) << 8) | (bytes[offset + 3] & 255); }
}
