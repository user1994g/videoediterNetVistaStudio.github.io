package com.netvistastudio.editor.android;

import org.junit.Test;
import static org.junit.Assert.*;

/** Android-free settings and coordinate convention checks. */
public final class ClipSettingsTest {
    @Test public void defaultsLeaveFittedSourceUnchanged() {
        StudioProject.ClipSettings value = new StudioProject.ClipSettings();
        assertEquals(1f, value.scale, 0f); assertEquals(0f, value.rotationDegrees, 0f);
        assertEquals(0f, value.positionX, 0f); assertEquals(0f, value.positionY, 0f);
        assertEquals(1f, value.opacity, 0f); assertEquals(0f, value.brightness, 0f);
        assertEquals(0f, value.contrast, 0f); assertEquals(1f, value.saturation, 0f);
        assertArrayEquals(new float[]{1f, 0f, 0f, 0f, 0f, 1f, 0f, 0f,
                0f, 0f, 1f, 0f, 0f, 0f, 0f, 1f}, value.canvasTransformMatrix(1920, 1080), 0.00001f);
    }

    @Test public void settingsCopyPreservesEveryPropertyWithoutAliasing() {
        StudioProject.ClipSettings value = new StudioProject.ClipSettings(2f, 35f, 0.3f, -0.4f, 0.6f, 0.2f, -0.3f, 1.7f);
        StudioProject.ClipSettings copy = value.copy();
        assertNotSame(value, copy);
        assertEquals(value.scale, copy.scale, 0f); assertEquals(value.rotationDegrees, copy.rotationDegrees, 0f);
        assertEquals(value.positionX, copy.positionX, 0f); assertEquals(value.positionY, copy.positionY, 0f);
        assertEquals(value.opacity, copy.opacity, 0f); assertEquals(value.brightness, copy.brightness, 0f);
        assertEquals(value.contrast, copy.contrast, 0f); assertEquals(value.saturation, copy.saturation, 0f);
    }

    @Test public void normalizedPositionMovesHalfCanvasAndPositiveYIsUp() {
        StudioProject.ClipSettings value = new StudioProject.ClipSettings(1f, 0f, 1f, 0.5f, 1f, 0f, 0f, 1f);
        float[] matrix = value.canvasTransformMatrix(1280, 720);
        assertEquals("Normalized X=1 is half of output width", 640f, matrix[12] * 1280f / 2f, 0.001f);
        assertEquals("Positive GL Y means moving up by half of that fraction of output height", 180f,
                matrix[13] * 720f / 2f, 0.001f);
    }

    @Test public void rotationUsesPixelAspectAndKeepsCanvasDimensionsFixed() {
        StudioProject.ClipSettings value = new StudioProject.ClipSettings(1f, 90f, 0f, 0f, 1f, 0f, 0f, 1f);
        float[] matrix = value.canvasTransformMatrix(1920, 1080);
        // A point 100 pixels right of center becomes exactly 100 pixels above center.
        float inputX = 200f / 1920f;
        assertEquals(0f, matrix[0] * inputX * 1920f / 2f, 0.0001f);
        assertEquals(100f, matrix[1] * inputX * 1080f / 2f, 0.0001f);
        // A point above center becomes left of center, proving positive CCW rotation.
        float inputY = 200f / 1080f;
        assertEquals(-100f, matrix[4] * inputY * 1920f / 2f, 0.0001f);
        assertEquals(0f, matrix[5] * inputY * 1080f / 2f, 0.0001f);
    }

    @Test public void scaleDoesNotScalePositionOffset() {
        StudioProject.ClipSettings value = new StudioProject.ClipSettings(2f, 0f, 0.5f, -0.5f, 1f, 0f, 0f, 1f);
        float[] matrix = value.canvasTransformMatrix(1080, 1920);
        assertEquals(2f, matrix[0], 0f); assertEquals(2f, matrix[5], 0f);
        assertEquals(0.5f, matrix[12], 0f); assertEquals(-0.5f, matrix[13], 0f);
    }

    @Test public void allSettingsRejectNonFiniteAndOutOfRangeNumbers() {
        float[] defaults = {1f, 0f, 0f, 0f, 1f, 0f, 0f, 1f};
        float[] below = {0f, -361f, -1.01f, -1.01f, -0.01f, -1.01f, -1.01f, -0.01f};
        float[] above = {8.01f, 361f, 1.01f, 1.01f, 1.01f, 1.01f, 1.01f, 2.01f};
        for (int index = 0; index < defaults.length; index++) {
            for (float invalid : new float[]{below[index], above[index], Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY}) {
                float[] values = defaults.clone(); values[index] = invalid;
                try {
                    new StudioProject.ClipSettings(values[0], values[1], values[2], values[3], values[4], values[5], values[6], values[7]);
                    fail("Accepted invalid setting at index " + index + ": " + invalid);
                } catch (IllegalArgumentException expected) { /* validation is the contract */ }
            }
        }
    }

    @Test public void validBoundaryValuesAreRetained() {
        new StudioProject.ClipSettings(0.05f, -360f, -1f, -1f, 0f, -1f, -1f, 0f);
        new StudioProject.ClipSettings(8f, 360f, 1f, 1f, 1f, 1f, 1f, 2f);
    }

    @Test(expected = IllegalArgumentException.class) public void zeroCanvasIsRejected() {
        new StudioProject.ClipSettings().canvasTransformMatrix(0, 1080);
    }
}
