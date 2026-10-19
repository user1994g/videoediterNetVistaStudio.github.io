package com.netvistastudio.editor.android;

import android.annotation.TargetApi;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.ColorSpace;
import android.graphics.ImageDecoder;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.os.Build;
import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.nio.ByteBuffer;

/** Full-resolution, orientation-aware native decoding. No thumbnail is substituted
 * for original pixels. The caller owns the returned software sRGB bitmap. */
final class PhotoImageImport {
    private PhotoImageImport() {}

    static Bitmap decode(byte[] encoded, long workingBudget) throws IOException {
        if (encoded == null || encoded.length == 0) throw new IOException("The image is empty.");
        try {
            return Build.VERSION.SDK_INT >= 28
                    ? decodeModern(encoded, workingBudget) : decodeLegacy(encoded, workingBudget);
        } catch (OutOfMemoryError error) {
            throw new IOException("Insufficient memory to import this full-resolution photo. Your current edit remains intact.", error);
        }
    }

    @TargetApi(28)
    private static Bitmap decodeModern(byte[] encoded, long workingBudget) throws IOException {
        Bitmap image = null;
        try {
            // ImageDecoder applies encoded EXIF orientation, including mirrored
            // camera images. Software allocation is required by our compositor.
            image = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(encoded)), (decoder, info, source) -> {
                try { preflight(info.getSize().getWidth(), info.getSize().getHeight(), encoded.length, workingBudget); }
                catch (IOException error) { throw new DecodeRejected(error); }
                decoder.setAllocator(ImageDecoder.ALLOCATOR_SOFTWARE);
                decoder.setTargetColorSpace(ColorSpace.get(ColorSpace.Named.SRGB));
                decoder.setOnPartialImageListener(failure -> false);
            });
            PhotoDocument.validateSize(image.getWidth(), image.getHeight());
            if (image.getConfig() != Bitmap.Config.ARGB_8888) {
                Bitmap normalized = image.copy(Bitmap.Config.ARGB_8888, false);
                if (normalized == null) throw new IOException("Unable to prepare software photo pixels.");
                image.recycle(); image = normalized;
            }
            Bitmap complete = image; image = null; return complete;
        } catch (DecodeRejected error) {
            throw error.reason;
        } catch (IllegalArgumentException error) {
            throw new IOException("This image encoding cannot be imported on this device.", error);
        } finally {
            if (image != null) image.recycle();
        }
    }

    /** API 26/27 fallback kept independently testable on current devices. */
    static Bitmap decodeLegacy(byte[] encoded, long workingBudget) throws IOException {
        Bitmap source = null, oriented = null;
        try {
            BitmapFactory.Options bounds = new BitmapFactory.Options(); bounds.inJustDecodeBounds = true;
            BitmapFactory.decodeByteArray(encoded, 0, encoded.length, bounds);
            preflight(bounds.outWidth, bounds.outHeight, encoded.length, workingBudget);
            int orientation = ExifInterface.ORIENTATION_NORMAL;
            try (ByteArrayInputStream input = new ByteArrayInputStream(encoded)) {
                orientation = new ExifInterface(input).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL);
            } catch (IOException error) {
                // Older platform ExifInterface does not recognise every image
                // format accepted by BitmapFactory. JPEG is supported on 26/27;
                // a broken JPEG metadata stream is not silently ignored.
                if (encoded.length >= 2 && (encoded[0] & 255) == 255 && (encoded[1] & 255) == 216)
                    throw new IOException("This JPEG's orientation metadata could not be read.", error);
            }
            BitmapFactory.Options options = new BitmapFactory.Options();
            options.inPreferredConfig = Bitmap.Config.ARGB_8888; options.inScaled = false;
            options.inPreferredColorSpace = ColorSpace.get(ColorSpace.Named.SRGB);
            source = BitmapFactory.decodeByteArray(encoded, 0, encoded.length, options);
            if (source == null) throw new IOException("That image could not be decoded.");
            Matrix matrix = orientationMatrix(orientation);
            oriented = Bitmap.createBitmap(source, 0, 0, source.getWidth(), source.getHeight(), matrix, false);
            if (oriented != source) source.recycle(); source = null;
            Bitmap complete = oriented; oriented = null; return complete;
        } catch (OutOfMemoryError error) {
            throw new IOException("Insufficient memory to orient this photo. Your original image remains unchanged.", error);
        } finally {
            if (source != null && source != oriented) source.recycle();
            if (oriented != null) oriented.recycle();
        }
    }

    /** Maps source pixel edges. createBitmap normalizes the negative bounds;
     * writing matrices explicitly avoids flip/rotation ordering ambiguities. */
    private static Matrix orientationMatrix(int orientation) {
        float[] values;
        switch (orientation) {
            case ExifInterface.ORIENTATION_FLIP_HORIZONTAL: values = new float[]{-1,0,0, 0,1,0, 0,0,1}; break;
            case ExifInterface.ORIENTATION_ROTATE_180: values = new float[]{-1,0,0, 0,-1,0, 0,0,1}; break;
            case ExifInterface.ORIENTATION_FLIP_VERTICAL: values = new float[]{1,0,0, 0,-1,0, 0,0,1}; break;
            case ExifInterface.ORIENTATION_TRANSPOSE: values = new float[]{0,1,0, 1,0,0, 0,0,1}; break;
            case ExifInterface.ORIENTATION_ROTATE_90: values = new float[]{0,-1,0, 1,0,0, 0,0,1}; break;
            case ExifInterface.ORIENTATION_TRANSVERSE: values = new float[]{0,-1,0, -1,0,0, 0,0,1}; break;
            case ExifInterface.ORIENTATION_ROTATE_270: values = new float[]{0,1,0, -1,0,0, 0,0,1}; break;
            default: values = new float[]{1,0,0, 0,1,0, 0,0,1}; break;
        }
        Matrix matrix = new Matrix(); matrix.setValues(values); return matrix;
    }

    private static void preflight(int width, int height, int encodedLength, long workingBudget) throws IOException {
        PhotoDocument.validateSize(width, height);
        // Decode, orientation/8-bit normalization, PNG staging and the immutable
        // layer retain can coexist. Reject before decoding, never downsample.
        long required = (long)width * height * 32 + (long)encodedLength * 2;
        if (workingBudget < required) throw new IOException("This full-resolution image needs about "
                + ((required + 1048575) / 1048576) + " MB of working memory. The original is not silently downsampled.");
    }

    private static final class DecodeRejected extends RuntimeException {
        final IOException reason;
        DecodeRejected(IOException reason) { super(reason); this.reason = reason; }
    }
}
