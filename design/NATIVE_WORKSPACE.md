# NetVista Studio native workspace contract

The macOS editor is the reference, not the first mobile Beta 7 screen. Use native
AppKit/UIKit/Qt/Android widgets and media engines. Never wrap the website.

## Shared appearance

Use the default `StudioThemePalette` from `StudioTheme.swift` on every platform:

| Token | RGB |
| --- | --- |
| windowBackground | #17191E |
| topBarBackground | #111317 |
| panelBackground | #20232A |
| workspaceBackground | #181B21 |
| cardBackground | #202833 |
| controlBackground | #242A33 |
| primaryText | #FFFFFF |
| secondaryText | #9DA6B5 |
| accent | #F05B5E |
| separator | #363B46 |
| videoClip | #356F9F |
| audioClip | #188B74 |

Use original NetVista logo, white **NetVista** (17 pt, semibold) and a separate
red **STUDIO** (10 pt, bold). Do not tint the entire brand blue. Body/property
text is 12–13 pt, section headings 10–11 pt, timecode monospaced 11 pt. Avoid
oversized system-button symbols or titles. Buttons never wrap a short label.
Corners 5–7 pt, separators 1 pt, padding 8–12 pt, tight related-control groups.

## Workspace arrangement

1. Top toolbar: brand, Studio Home, project title, account, open/save/export.
   Secondary actions can move into a native overflow menu at narrow widths.
2. Media Pool on left: imported sources, Import, Add selected/all; sources are
   distinct from their timeline instances so duplicates and split clips work.
3. Program Monitor center: aspect-fit frame, inspection-only video surface,
   dedicated transport bar below (play/pause, stop, previous/next, timecode).
4. Inspector on right: selected clip, trim, Motion/Effects and Colour controls;
   native scroll for settings, no settings hidden below a fixed screen edge.
5. Timeline below monitor: toolbar, seconds ruler, red playhead, named track
   lanes, blue video blocks and green audio. Zoom, horizontal pan, selection,
   playhead scrubbing, split, delete and drag/reorder must do real work.
6. Bottom navigation shows only implemented workspaces. No fake 3D/photo/game
   buttons suggesting those editors exist when that platform cannot run them.

Wide tablet/desktop keeps three panels with a larger center and resizable
splitters where native support permits. Tablet portrait and split-screen use
panel toggles/drawers. iPhone/Android phones retain monitor and timeline and
switch Media/Inspector panels through a compact native navigation strip.
Do not shrink a desktop UI until it is unreadable or disable phone support.
Use available window bounds/safe areas, not device-model string detection.

Touch: minimum 44 pt/dp action targets, compact 12–13 pt titles and 15–18 pt
symbols inside them. Desktop actions can be 28–34 pt tall. Respect accessibility
text sizes by scrolling/reflowing; never truncate indispensable controls.

## Behavior and compatibility

Imported clips can be added more than once. Editing properties updates the
selected timeline instance, survives save/load, undo/redo, split and duplication,
and uses the same transform/grade math in preview and export. Keep source fit
separate from user scale; scale 100% means the full source fitted to the output.
Opacity zero must actually show background, not an unchanged frame. Controls
without a selected clip are disabled and explain the required selection.

Keep identity/auth storage and 25-minute checks intact. First launch must not
prompt for Keychain before login. Do not invent placeholder Mac features or
change release versions/tags just to make the editions appear equivalent.

## Verification

Check iPad landscape/portrait/split width and iPhone portrait/landscape; Android
phone/tablet; desktop at 960x640 and 1500x930. Test two clips of different aspect
ratio, a rotated source, silent and audio sources, scrub across boundary, split,
duplicate/delete/move, zoom, save/reopen, undo/redo and export. Verify changed
motion/colour/opacity in decoded output pixels, not only by control callbacks.
List any remaining feature-parity gaps accurately in the handoff.
