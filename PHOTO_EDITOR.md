# Photos · NetVista Studio (native macOS beta)

Photos is a separate native editing window inside NetVista Studio. The Home icon returns to the shared Studio launcher without closing either editor.

## Start and save

- **File → New Document** creates a blank canvas: HD, square, portrait, story, 4K, A4, US Letter, or custom pixels and print resolution. Choose white, transparent or a custom background.
- **File → Import Image Layers** adds images to the existing document. Dropping image files into the window does the same.
- **Save / Save As** creates a self-contained `.netvistaphoto` v2 project with embedded layer pixels, masks, folders, adjustment properties, transforms and editable text metadata. Original image files are not required to reopen a v2 project. Older v1 projects still open when their referenced images are available.
- **Export** writes a flattened PNG (transparency) or JPEG (white background). The document's ppi is included. Export does not replace the layered project.

## Workspace

The compact File, Edit, Layer, Select and View menus contain working actions. The second bar follows the active tool. Photos starts with Brush selected and a visible two-column tip library. Choose **Brushes** or **Properties** in the right dock; the Layers panel remains visible below both. Size, opacity, flow and paint colour also remain accessible in the top options bar. Properties accept sliders or exact typed values. Pan with the Hand tool or trackpad; Command/Option-scroll zooms around the pointer. View provides Fit, Actual Pixels and ruler visibility.

Studio Home has separate Video/Photo launch cards and a searchable, filterable recent-project list. Successfully saved/opened projects are registered with macOS and appear when Home regains focus. Opening an editor keeps the Home window available; existing editor windows/documents are brought forward, not recreated.

## Layers and selections

- The Layers footer creates pixel layers, folders, masks and adjustment layers, duplicates or renames a layer, changes ordering, and deletes a layer. Hover over an icon for its name; the same actions are in the Layer menu.
- Blend modes, opacity and locking are directly above the list. Eye controls toggle visibility.
- Folders contain one level of layers. Select a folder twice to collapse/expand it. The folder's visibility, opacity, blend mode and lock affect its contents. Folder nesting is not implemented.
- Rectangle, freehand lasso and contiguous magic-wand selections constrain painting and fill. The wand's tolerance is in Brushes. **Select → Lift Selection to Layer** extracts selected pixels into a new layer so Move and Properties can resize, rotate or skew them around their own bounds.
- **Select → Crop to Selection** crops the document to a rectangular selection. Undo restores the previous canvas.
- Add a mask to reveal all, reveal/hide a selection, invert or remove a mask. Enable **Paint layer mask** in Brushes: black hides, white reveals. Erasing a mask reveals pixels; erasing an image removes opacity.

## Paint and retouch

- Hard round, soft round, chalk and calligraphy tips have adjustable size, hardness, stroke opacity and flow. Bracket keys change size. B/E select brush/eraser when the canvas has focus; V/H/Z/I select move/hand/zoom/eyedropper. A circular pointer indicates brush diameter. A continuous stroke is one undo step. Selecting a different tip preserves Eraser/Clone/Heal mode. Painting hidden or locked layers reports why nothing will be painted.
- Clone Stamp: Option-click a source on the selected layer, then paint. Healing uses a frozen source with local colour matching; it is **not** Photoshop's content-aware healing or generative fill.
- Bucket fills a connected colour region, constrained by the current selection. Eyedropper samples the visible composite.
- Text creates a separate layer with font, pixel size and colour; **Edit Text Layer** changes the text later. Painting directly on editable text is disabled—paint on a separate pixel layer instead.
- Rectangle, ellipse, line and freehand closed-polygon tools create separate raster shape layers. These are not editable vector paths.
- Click a palette swatch to use it; Option-click to edit it. The eight custom swatches persist between launches. The native foreground colour well opens the system colour picker.

## Brushes and compatibility

Choose **Import ABR…** in Brushes, or drop `.abr` / `.netvistabrush` files onto the photo window. The import picker also accepts PNG/JPEG tips and multiple files. Parsing and library encoding run in a background queue. Search the visible tip grid to find imported brushes. Basic round/computed brushes and **8/16-bit sampled tips** are supported in v1/v2 and v6/v7/v9/v10 (subversions 1/2), raw or PackBits. Modern descriptor metadata supplies names and ordinary diameter, spacing, angle, roundness and hardness. Sampled-tip hardness is baked into the bitmap, so that slider is disabled rather than pretending to change it.

Photoshop pressure/scatter/texture dynamics, dual brushes, tip flips and wet/bristle/mixer simulation are **not reproduced**. Packs with usable tips plus unsupported records import usable tips and show a compatibility report. Structural corruption that prevents safely finding the next record fails the file. Brush structure was checked against [GIMP](https://github.com/GNOME/gimp/blob/master/app/core/gimpbrush-load.c) and [ag-psd](https://github.com/Agamnentzar/ag-psd/blob/master/src/abr.ts); NetVista uses an independent bounded Swift parser. Regression tests include generated raw/RLE/16-bit/computed/corrupt fixtures and two [Photoshop-exported fixtures](https://github.com/SethRobinson/Patchy/tree/main/test-fixtures/abr) (`photoshop-dynamics.abr`, `photoshop-dual-brush.abr`). These external packs were used only in temporary storage, not bundled with the app. This does not establish compatibility with every commercial brush pack.

**Define from Layer** uses the layer or active selection as a tip (dark pixels paint; white/transparent pixels do not). Custom tips are reduced to at most 512 px. Save Tip writes a reusable `.netvistabrush`. Imported/custom tips persist in the per-user library (96 MB encoded / 1,024-tip limit). ABR files are capped at 128 MB, each sampled tip at 8192 px per side / 32 megapixels and each decoded batch at 64 MB. Preview/stroke tip generation is bounded independently of the original bitmap size.

## Adjustments

Properties provides exposure, brightness/contrast, hue/saturation, vibrance, highlights/shadows, white balance, levels, a three-handle tone curve, blur, sharpen, grain, sepia and vignette. The numeric curve fields are synchronized with the graph. An adjustment layer affects the composite below it, inside its folder, and can have its own mask and opacity. The graph's three interior input positions are fixed; arbitrary curve points and per-channel curve editors are not yet implemented.

## Current boundaries and verification

- This implementation targets the native macOS photo editor; it does not add these systems to the Windows/Linux editor.
- Documents are 8-bit RGB, at most 16,000 px per side and 64 megapixels total. No CMYK, PSD/PSB import/export or Photoshop plug-in compatibility is claimed.
- Undo has up to 80 steps, reduced for large documents by an approximate 512 MB history budget. No disk-backed history or tiled painting engine yet.
- Regression checks exercise real pixels: brush opacity/spacing, selection clipping, coordinate orientation, clone/eraser, immutable history sources, masks, folder visibility, adjustment composition, embedded project round trips, and ABR parsing failures. The native workspace is rendered offscreen at 1320×820 and 980×640 to inspect layout.

Run the checks on macOS with graphics access:

```sh
xcrun swiftc -module-cache-path /private/tmp/netvista-photo-check-cache PhotoRaster.swift Tests/PhotoRasterChecks.swift -o /private/tmp/netvista-photo-raster-checks
/private/tmp/netvista-photo-raster-checks
xcrun swiftc -D PHOTO_EDITOR_CHECKS -module-cache-path /private/tmp/netvista-photo-check-cache PhotoRaster.swift PhotoEditor.swift Tests/PhotoWorkspaceChecks.swift -o /private/tmp/netvista-photo-workspace-checks
/private/tmp/netvista-photo-workspace-checks
```

The second harness opens no visible windows and writes only temporary project/screenshot fixtures in `/private/tmp`.
