package com.netvistastudio.editor.android;

import org.junit.Test;
import static org.junit.Assert.*;

public final class GradeControlValuesTest {
    @Test public void neutralIsExactlyTheNativeNoOp() {
        assertEquals(100f, GradeControlValues.contrastPercent(0f), 0f);
        assertEquals(0f, GradeControlValues.nativeContrast(100f), 0f);
    }

    @Test public void displayedPercentRepresentsActualContrastFactor() {
        assertEquals(66.66111f, GradeControlValues.contrastPercent(-0.2f), 0.0001f);
        assertEquals(149.98125f, GradeControlValues.contrastPercent(0.2f), 0.0001f);
        assertEquals(-0.1110667f, GradeControlValues.nativeContrast(80f), 0.0000001f);
        assertEquals(0.3334f, GradeControlValues.nativeContrast(200f), 0.0000001f);
    }

    @Test public void nativeValuesWithinVisibleRangeRoundTrip() {
        for (float nativeValue : new float[]{-1f, -0.9f, -0.5f, -0.2f, 0f, 0.2f, 0.5f, 0.6f}) {
            assertEquals("Native contrast " + nativeValue, nativeValue,
                    GradeControlValues.nativeContrast(GradeControlValues.contrastPercent(nativeValue)), 0.000001f);
        }
    }

    @Test public void validFactorPercentagesRoundTrip() {
        for (float percent : new float[]{0f, 25f, 50f, 80f, 100f, 125f, 200f, 300f, 400f}) {
            assertEquals("Contrast factor percent " + percent, percent,
                    GradeControlValues.contrastPercent(GradeControlValues.nativeContrast(percent)), 0.0001f);
        }
    }

    @Test public void displayClampsExtremeLegacyContrastWithoutChangingItsNativeValue() {
        assertEquals(0f, GradeControlValues.contrastPercent(-1f), 0f);
        assertEquals(400f, GradeControlValues.contrastPercent(1f), 0f);
        assertEquals(400f, GradeControlValues.contrastPercent(0.9f), 0f);
        float maximumVisible = GradeControlValues.nativeContrast(400f);
        assertEquals(0.60008f, maximumVisible, 0.0000001f);
        assertTrue(maximumVisible >= -1f && maximumVisible <= 1f);
        assertEquals(400f, GradeControlValues.contrastPercent(maximumVisible), 0.0001f);
    }

    @Test public void invalidDisplayValuesAreRejected() {
        for (float invalid : new float[]{-0.01f, 400.01f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY}) {
            try { GradeControlValues.nativeContrast(invalid); fail("Accepted invalid UI contrast " + invalid); }
            catch (IllegalArgumentException expected) { /* expected */ }
        }
    }

    @Test public void invalidNativeValuesAreRejected() {
        for (float invalid : new float[]{-1.01f, 1.01f, Float.NaN, Float.POSITIVE_INFINITY, Float.NEGATIVE_INFINITY}) {
            try { GradeControlValues.contrastPercent(invalid); fail("Accepted invalid native contrast " + invalid); }
            catch (IllegalArgumentException expected) { /* expected */ }
        }
    }
}
