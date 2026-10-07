# Effects and Colour — native workflow

Both video tool windows use the same theme-backed header, selected-clip context,
navigation strip, panels, editable numeric controls and Preview / Revert / Apply
workflow. They remain separate native windows, with the main timeline and program
monitor accessible behind them. Their window minimum is 820 × 620.

## Multiple tools at once

Effects and Colour are independent floating, resizable tool windows, not
exclusive tabs or modal dialogs. Open either from the editor or the macOS
**Window** menu. **Window → Open Effects & Colour Together** opens both;
**Arrange Video Tool Windows** places them side-by-side where the screen can
fit their minimum sizes, or staggers them on smaller screens. You can also drag
either window to another display. Focusing an open tool preserves its position,
unfinished values, selected node and keyframe settings.

Both previews combine on the selected clips. Applying one tool preserves the
other tool's unfinished preview. Minimizing, changing pages or switching focus
does not cancel edits. **Revert Preview** or closing a tool discards only that
tool's unfinished preview; Apply saves it. Selecting different clips loads their
saved settings into both tools.

## Effects

Select one or more timeline videos, then open Effects. Use **Effects** to browse
the library, see the applied stack and edit settings. Motion and Opacity remain
fixed controls; optional picture effects have their own order. Use **Keyframes**
for the larger animation grid instead of squeezing it beside every effect.
The Keyframes tab has its own linked property slider and exact-value field:
choose Scale or Opacity, move the playhead, set the value, then Add / Update.
Auto Keyframe can record those changes without switching back to Effects.

Dragging a slider previews immediately. Numeric fields accept exact values. Use
Apply to save the settings to the selected clips; Revert restores saved values.
The program surface is inspection-only, and playback stays in its transport bar.
Optional AI cutout still requires an explicit model download.

## Colour

Select clips, then use Nodes, Primaries, Curves, Qualifier, Scopes or LUT. Add or
duplicate a node before editing its wheels/curves/qualifier; controls that need a
node are disabled until one is selected. Node reordering retains each node's
own settings. Reset Grade previews neutral base controls, an empty node stack
and no LUT; Apply commits it to all selected video clips.

Scopes sample the currently graded **selected clip**, not the full composite of
all timeline layers. They are bounded SDR/sRGB preview scopes, not a calibrated
HDR or broadcast-measurement system. Waveform/parade preserve source horizontal
position, and all four views use explicitly rendered RGBA samples. Decoding and
sample rendering run in the background, with one replaceable pending frame;
playback requests are limited to four sampled frames per second. The program
monitor continues to show the full timeline composite.

## Design references and checks

The applied-stack/property hierarchy follows the workflow described in Adobe's
[Effect Controls documentation](https://helpx.adobe.com/premiere/desktop/add-video-effects/apply-video-effects/view-effects-in-the-effect-controls-panel.html),
adapted to NetVista's existing controls and backend rather than copied app code.
The modelling operations follow the concepts in Blender's
[mesh-editing manual](https://docs.blender.org/manual/en/latest/modeling/meshes/editing/index.html);
see [MODELING.md](MODELING.md) for actual supported tools and limits.

`Tests/VideoWorkspaceChecks.swift` covers native controls and layouts;
`Tests/GradeScopeChecks.swift` covers bounded samples, channel/column accuracy,
scope drawing and stale background work. Use a graphics-capable macOS session
for pixel assertions; the tests reject an unavailable all-zero render context.
