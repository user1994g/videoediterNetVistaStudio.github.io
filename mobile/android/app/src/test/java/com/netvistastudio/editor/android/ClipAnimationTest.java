package com.netvistastudio.editor.android;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.EnumMap;
import java.util.List;
import org.junit.Test;
import static org.junit.Assert.*;

public final class ClipAnimationTest {
    private static final String ID = "fe813cc1-e815-4da4-a520-613366184629";
    private static ClipAnimation curve(ClipAnimation.Curve interpolation) {
        return new ClipAnimation().withKeyframe(ClipAnimation.Property.OPACITY, 1000, 0, interpolation)
                .withKeyframe(ClipAnimation.Property.OPACITY, 2000, 1, ClipAnimation.Curve.LINEAR);
    }
    @Test public void linearHoldsEndpointsAndInterpolatesActualFractionalFrameTime() {
        ClipAnimation keys = curve(ClipAnimation.Curve.LINEAR);
        assertEquals(0, keys.valueAt(ClipAnimation.Property.OPACITY, 500, .8f), 0);
        assertEquals(.5f, keys.valueAt(ClipAnimation.Property.OPACITY, 1500, .8f), .000001f);
        assertEquals(.2505f, keys.valueAt(ClipAnimation.Property.OPACITY, 1250.5, .8f), .000001f);
        assertEquals(1, keys.valueAt(ClipAnimation.Property.OPACITY, 2500, .8f), 0);
        assertEquals(.8f, keys.valueAt(ClipAnimation.Property.BRIGHTNESS, 1500, .8f), 0);
    }
    @Test public void holdChangesOnTheExactRightDiamond() {
        ClipAnimation keys = curve(ClipAnimation.Curve.HOLD);
        assertEquals(0, keys.valueAt(ClipAnimation.Property.OPACITY, 1999.9, 1), 0);
        assertEquals(1, keys.valueAt(ClipAnimation.Property.OPACITY, 2000, 0), 0);
    }
    @Test public void easeInOutUsesSmoothstepAndNotLinear() {
        ClipAnimation keys = curve(ClipAnimation.Curve.EASE_IN_OUT);
        assertEquals(.15625f, keys.valueAt(ClipAnimation.Property.OPACITY, 1250, 1), .000001f);
        assertEquals(.5f, keys.valueAt(ClipAnimation.Property.OPACITY, 1500, 1), .000001f);
        assertEquals(.84375f, keys.valueAt(ClipAnimation.Property.OPACITY, 1750, 1), .000001f);
        assertEquals(.0625f, curve(ClipAnimation.Curve.EASE_IN).valueAt(ClipAnimation.Property.OPACITY, 1250, 1), .000001f);
        assertEquals(.4375f, curve(ClipAnimation.Curve.EASE_OUT).valueAt(ClipAnimation.Property.OPACITY, 1250, 1), .000001f);
    }
    @Test public void updatesAreImmutableOrderedAndRemoveRevealsStaticValue() {
        ClipAnimation original = curve(ClipAnimation.Curve.LINEAR);
        ClipAnimation updated = original.withKeyframe(ClipAnimation.Property.OPACITY, 1000, .75f, ClipAnimation.Curve.HOLD);
        assertEquals(2, updated.points(ClipAnimation.Property.OPACITY).size());
        assertEquals(0, original.points(ClipAnimation.Property.OPACITY).get(0).value, 0);
        assertEquals(.75f, updated.points(ClipAnimation.Property.OPACITY).get(0).value, 0);
        ClipAnimation removed = updated.withoutKeyframe(ClipAnimation.Property.OPACITY, 1000);
        assertEquals(1, removed.points(ClipAnimation.Property.OPACITY).size());
        assertEquals(.4f, removed.withoutProperty(ClipAnimation.Property.OPACITY).valueAt(ClipAnimation.Property.OPACITY, 1000, .4f), 0);
        try { updated.points(ClipAnimation.Property.OPACITY).clear(); fail("Mutable keyframe list"); } catch (UnsupportedOperationException expected) { }
    }
    @Test public void splitDuplicateTrimAndSavedHistoryRetainSourceAnchoringWithoutSharingMutability() {
        StudioProject project = new StudioProject();
        StudioProject.Clip clip = new StudioProject.Clip(ID, "media/" + ID + ".video", "Animated", 10000, 1000, 7000,
                new StudioProject.ClipSettings(), curve(ClipAnimation.Curve.LINEAR));
        project.clips.add(clip); StudioProject history = project.copy();
        StudioProject.Clip right = project.split(0, 1500);
        assertEquals(.5f, clip.settingsAtSourceMs(1500).opacity, 0);
        assertEquals(.5f, right.settingsAtSourceMs(right.inMs).opacity, 0);
        StudioProject.Clip duplicate = project.duplicate(1); duplicate.trim(1700, 5000);
        assertEquals(.7f, duplicate.settingsAtSourceMs(duplicate.inMs).opacity, .000001f);
        duplicate.animation = duplicate.animation.withKeyframe(ClipAnimation.Property.OPACITY, 1700, .2f, ClipAnimation.Curve.HOLD);
        assertEquals(.7f, right.settingsAtSourceMs(1700).opacity, .000001f);
        assertEquals(1, history.clips.size()); assertEquals(7000, history.clips.get(0).outMs);
        assertEquals(.5f, history.clips.get(0).settingsAtSourceMs(1500).opacity, 0);
        assertTrue(clip.fullSource().animation.isEmpty());
    }
    @Test public void everyPropertyValidatesFiniteBoundsAndEvaluatesIndependently() {
        ClipAnimation animation = new ClipAnimation();
        for (ClipAnimation.Property property : ClipAnimation.Property.values()) {
            animation = animation.withKeyframe(property, 0, property.minimum, ClipAnimation.Curve.LINEAR)
                    .withKeyframe(property, 1000, property.maximum, ClipAnimation.Curve.LINEAR);
            float midpoint = (property.minimum + property.maximum) / 2;
            assertEquals(midpoint, animation.valueAt(property, 500, 999), .000001f);
            for (float invalid : new float[]{Float.NaN, Float.POSITIVE_INFINITY, property.maximum + 1, property.minimum - 1}) {
                try { animation.withKeyframe(property, 1, invalid, ClipAnimation.Curve.HOLD); fail("Accepted invalid " + property); } catch (IllegalArgumentException expected) { }
            }
        }
        StudioProject.ClipSettings evaluated = animation.evaluate(new StudioProject.ClipSettings(), 500);
        assertEquals(4.025f, evaluated.scale, .000001f); assertEquals(.5f, evaluated.opacity, 0);
        assertEquals(0, evaluated.contrast, 0); assertEquals(1, evaluated.saturation, 0);
    }
    @Test public void rejectsDuplicateUnorderedOutOfSourceAndUnboundedKeys() {
        EnumMap<ClipAnimation.Property, List<ClipAnimation.Keyframe>> input = new EnumMap<>(ClipAnimation.Property.class);
        for (List<ClipAnimation.Keyframe> invalid : Arrays.asList(
                Arrays.asList(new ClipAnimation.Keyframe(10, 0, ClipAnimation.Curve.LINEAR), new ClipAnimation.Keyframe(10, 1, ClipAnimation.Curve.LINEAR)),
                Arrays.asList(new ClipAnimation.Keyframe(20, 0, ClipAnimation.Curve.LINEAR), new ClipAnimation.Keyframe(10, 1, ClipAnimation.Curve.LINEAR)))) {
            input.put(ClipAnimation.Property.OPACITY, invalid);
            try { new ClipAnimation(input); fail("Accepted invalid point order"); } catch (IllegalArgumentException expected) { }
        }
        List<ClipAnimation.Keyframe> tooMany = new ArrayList<>();
        for (int index = 0; index <= ClipAnimation.MAX_POINTS_PER_PROPERTY; index++) tooMany.add(new ClipAnimation.Keyframe(index, 1, ClipAnimation.Curve.LINEAR));
        input.put(ClipAnimation.Property.OPACITY, tooMany);
        try { new ClipAnimation(input); fail("Unbounded points accepted"); } catch (IllegalArgumentException expected) { }
        try { curve(ClipAnimation.Curve.LINEAR).validateDuration(1500); fail("Out-of-source key accepted"); } catch (IllegalArgumentException expected) { }
        try { new ClipAnimation.Keyframe(-1, 1, ClipAnimation.Curve.LINEAR); fail("Negative key accepted"); } catch (IllegalArgumentException expected) { }
        try { curve(ClipAnimation.Curve.LINEAR).valueAt(ClipAnimation.Property.OPACITY, Double.NaN, 1); fail("Invalid time accepted"); } catch (IllegalArgumentException expected) { }
    }
    @Test public void exactPerPropertyAndPerClipCapsAreAcceptedAndOverflowIsRejected() {
        EnumMap<ClipAnimation.Property, List<ClipAnimation.Keyframe>> tracks = new EnumMap<>(ClipAnimation.Property.class);
        for (int index = 0; index < 5; index++) {
            ClipAnimation.Property property = ClipAnimation.Property.values()[index]; List<ClipAnimation.Keyframe> points = new ArrayList<>();
            for (int time = 0; time < ClipAnimation.MAX_POINTS_PER_PROPERTY; time++) points.add(new ClipAnimation.Keyframe(time, property.minimum, ClipAnimation.Curve.LINEAR));
            tracks.put(property, points);
        }
        ClipAnimation maximum = new ClipAnimation(tracks);
        assertEquals(2000, maximum.points(ClipAnimation.Property.OPACITY).size());
        maximum.withKeyframe(ClipAnimation.Property.OPACITY, 1000, .5f, ClipAnimation.Curve.HOLD);
        try { maximum.withKeyframe(ClipAnimation.Property.BRIGHTNESS, 0, 0, ClipAnimation.Curve.LINEAR); fail("More than10,000 clip keys accepted"); }
        catch (IllegalArgumentException expected) { }
    }
}
