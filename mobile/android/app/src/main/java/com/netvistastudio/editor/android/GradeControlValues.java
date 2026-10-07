package com.netvistastudio.editor.android;

/** Android-free display conversions. Project files retain Media3's native grade parameters. */
public final class GradeControlValues {
    private static final double CONTRAST_DENOMINATOR = 1.0001;
    public static final float MAX_CONTRAST_PERCENT = 400f;
    private GradeControlValues() {}

    /**
     * Displays the actual Media3 contrast factor as a percentage, capped at the UI's 400%.
     * Native zero is exactly a no-op and is shown as 100%, rather than 99.99%.
     * Legacy values above the visible factor cap are not rewritten by this conversion.
     */
    public static float contrastPercent(float nativeContrast) {
        if (!Float.isFinite(nativeContrast) || nativeContrast < -1f || nativeContrast > 1f) {
            throw new IllegalArgumentException("Native contrast must be finite and between -1 and 1.");
        }
        if (nativeContrast == 0f) return 100f;
        double percent = 100 * (1 + (double) nativeContrast) / (CONTRAST_DENOMINATOR - nativeContrast);
        return (float) Math.max(0, Math.min(MAX_CONTRAST_PERCENT, percent));
    }

    /** Converts a valid 0–400% factor to the saved Media3 native adjustment in [-1, 1]. */
    public static float nativeContrast(float percent) {
        if (!Float.isFinite(percent) || percent < 0f || percent > MAX_CONTRAST_PERCENT) {
            throw new IllegalArgumentException("Contrast must be finite and between 0 and 400 percent.");
        }
        if (percent == 100f) return 0f;
        double factor = percent / 100.0;
        return (float) ((CONTRAST_DENOMINATOR * factor - 1) / (factor + 1));
    }
}
