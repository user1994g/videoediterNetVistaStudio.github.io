# 3D Editor — native modelling workspace

Open **Studio Home → 3D Editor**, or **Studio → 3D Editor** (Command-4).
The home screen and your other editors stay open. This is a separate native
macOS workspace, not the video editor's 3D Scene window and not a Blender embed.

## Start a model

New projects start empty. Add a Cube, Sphere, Plane or Cylinder from **Add Mesh**.
Choose an object in Scene Collection or click it in the viewport. Set its name,
position, rotation, scale, visibility and surface colour in the right inspector.
Duplicate uses Command-D. Undo/redo retain up to 30 modelling changes, with
history trimmed against a 192 MB logical geometry estimate for dense models.
The latest operation is always retained; this estimate is not total app RAM.

Drag to orbit and scroll to zoom. **Focus / F** frames selection; **Frame all**
frames visible objects. Option-drag always orbits, even over an editable vertex.
Choose Solid or Wireframe display from the viewport toolbar. The view menu offers
Perspective plus orthographic Front, Right, Top, Back, Left and Bottom views.
Right-click a model to access selection-aware edit actions without leaving the
viewport. The status strip shows the active mode and selected object/face count.
The inspector separates **Geometry**, **Transform** and **Physics** properties,
so brush and face tools are not buried above a long list of unrelated controls.
Entering Face, Vertex or Sculpt mode returns to Geometry automatically.

## Sculpt a shape

Choose Draft, Balanced or High detail, then click **Sculpt sphere** for a
smooth-shaded mesh ready to reshape. Or select an existing object and choose
**Sculpt surface / Sculpt mode**. Click and drag directly on the model's sides.
Use Option-drag to orbit or the view menu to reach its back. Sculpting edits
actual mesh vertices and is retained by native saves and OBJ exports.

- **Draw** raises the surface along the brush normal; Subtract carves inward.
- **Clay** builds a shallow plateau for laying down broader volumes; inverted
  Clay carves a shallow plane.
- **Inflate** pushes vertices along their individual surface normals.
- **Crease** cuts a groove while pinching its sides. Control raises a ridge.
- **Smooth** relaxes local bumps using neighbouring vertices.
- **Flatten** draws the surface towards the tangent plane under the brush.
- **Scrape** shaves the highest part of the surface below the brush plane;
  inverted Scrape fills low points instead.
- **Pinch** pulls the surface towards the brush centre; inverted Pinch spreads it.
- **Grab** pulls a region with soft falloff as you drag. It uses the original
  stroke shape so motion does not accumulate with mouse event frequency.
- **Mask** paints soft per-vertex protection without changing the shape. Darker
  regions are more protected; fully masked vertices do not move with any brush.
  Control erases protection. **Clear mask** removes it; **Invert mask** protects
  the unmasked regions instead. M selects Mask and Option-M clears the mask.

Radius and Strength are live sliders. Radius is in mesh-local units, so object
scaling also scales the brush. The outline shows the brush tangent circle;
mask shading shows protection separately. **[ / ]** changes radius. **Shift** temporarily smooths while painting
(hold it before starting a Grab stroke to smooth instead). **Control** reverses
directional brushes or erases Mask. **Option-drag** always navigates the camera.

Enable **Mirror X** to edit both sides around the object's local X=0 plane.
**Front-facing only** excludes vertices whose normals face away from the brush;
it is not a full occlusion mask for folded surfaces. Through surface disables
that protection. Symmetry does not create missing geometry.

One complete stroke is one undo step. **Escape** restores the pre-stroke mesh.
Brushes affect existing vertices; they do not continuously remesh. **Auto sculpt
detail**, on by default, subdivides sparse meshes on the first stroke until
they have at least 512 faces, within the scene budget. A cube now responds when
you press the middle of its side, rather than requiring a corner under the brush.
Flat preparation retains the existing silhouette, and preparation plus the
stroke is one undo. Escape also restores the original sparse topology. Disable
Auto sculpt detail if you want complete control over topology.

Use **Subdivide · preserve shape** for more flat detail or **Smooth subdivide ·
round shape** for welded Catmull–Clark smoothing. Preflight shows the next level's
counts, and oversized operations are refused without changing the document.
Pointer motion is resampled into overlapping screen-space stamps, capped at
16 per event (4 above 20,000 vertices) to avoid unbounded work. Smooth-shaded
meshes use shared indexed render buffers. Brush normal calculations are limited
to the brush footprint. Very fast strokes and dense meshes can still be less responsive
than a dedicated sculpting engine. Masks are saved in native projects and
interpolated when subdividing; they are not exported into OBJ.

## Edit geometry

- **Object mode:** transform, duplicate or delete whole meshes.
- **Face mode:** click a face; **Shift-click** adds/removes neighbours from a
  region. Selected faces turn orange. **A / Select all** selects the mesh's
  faces, and Option-A / Deselect clears the selection. **Tab** switches between
  Object and Face mode.
  **Extrude region / E** creates connected caps along the selection's averaged
  normal, adding walls only at its boundary: shared cap vertices are welded,
  and there are no extra walls between neighbouring faces. Negative distances
  extrude inward. Opposing/all-closed face selections cannot be extruded; use
  a surface patch instead. **Inset individual faces / I** adds a separate inner
  ring per face using a fraction from 0.01 to 0.95 (not one region-wide inset).
  Delete removes all selected faces as one undo step.
  Move region uses Distance without creating geometry; Scale selected region
  scales the shared vertices once around the selection centre.
  **Extrude individual faces** uses the same Distance but moves each cap along
  its own normal, rather than the connected region's average normal.
  **Grow / Shrink** expand or contract an edge-connected face selection.
  **Select linked / L** selects the connected face island without crossing to
  separate overlapping parts. Selection changes do not consume undo steps.
  **Loop cut / Control-R** previews a yellow line across connected quads.
  Pick Direction A/B and slide Cut position (1–99%), then **Apply loop cut**.
  **Cancel / Escape** removes the preview without changing your mesh. The
  whole strip is split with welded edge points as one undo step; sculpt masks
  interpolate at the new points. The preview slider reuses the strip topology
  instead of rebuilding the full adjacency map on every mouse event.
  Cuts stop at open boundaries. A strip that reaches a triangle, inconsistent
  winding or a non-manifold edge is refused, avoiding partial cuts/T-junctions.
  This is a single quad-strip cut, not a freehand knife tool or general remesher.
- **Vertex mode:** click a vertex dot and drag it in the camera plane, or enter
  exact local X/Y/Z coordinates. **Snap 0.1** snaps dragged vertex coordinates.
  A complete drag is one undo step. Only the first 2,500 vertices have viewport
  dots, to keep interaction manageable; faces and transforms still work on
  larger meshes. Individual vertex deletion is not available yet.
  Enable **Proportional editing** to move nearby vertices with smooth falloff.
  Influence radius controls the region. X/Y/Z locks constrain the local axis.
- **Flat subdivision** preserves the shape and shares edge vertices.
- **Smooth subdivision** uses welded Catmull–Clark geometry, rounding the shape.
  It is a committed, undoable mesh edit, not a live modifier stack.
- **Apply transforms to mesh** bakes the object transform into its vertices.

Face and region extrusion/inset preserve the surrounding topology. This version does
not prevent self-intersections from extreme edits. Smooth/Flat shading changes
lighting, not geometry; the choice is stored with each object.

## Build a detailed creature

**Dragon starter** creates an original procedural, editable dragon with 48
separate parts: body, chest, neck, head, jaw, tail, legs, feet, claws, eyes, horns,
wing membranes/fingers and back spines. Draft has about 10,000 vertices, Balanced
31,000, and High 105,000. Choose a part in Scene Collection, sculpt it directly,
or transform it in Object mode. No downloaded asset or AI model is required.

This is a starting shape, not a finished production character, welded body or
animated rig. **Join visible meshes** combines transformed geometry into one
mesh, preserving masks and using one surface colour. It does not weld intersecting parts, retopologize them,
or retain separate physics bodies. Hide objects you do not want joined; the
operation is undoable and checks the combined mesh limit.

## Optional local helper

**Local AI helper…** opens a native plan-review window. Choose **Download model…**
and approve the optional Qwen2.5 0.5B GGUF download (about 491 MB), or choose
**Not now** to continue without AI. The local CPU runtime is included in the app;
no Ollama installation or background server is needed. Download shows progress,
supports cancellation/retry, and verifies the pinned file before enabling AI.
**Remove model…** frees its disk space without touching your projects or other
models. It suggests native shapes, a dragon starter,
subdivision or smoothing; it is not text-to-mesh generation. Prompts stay on
the local runtime after download. Review and press **Apply Plan** to make one
undoable change. If the scene/selection changed while thinking, ask again.
No generated code is executed. See [local helper details](MODELING_AI.md).

## Optional physics

In **Object mode**, choose Off, Static collider or Dynamic body in the object's
Physics properties. Set mass, friction, bounce, damping and gravity. Open
**Physics preview…**, then Play/Pause/Step/Reset while watching the main viewport.
Playback switches to Object mode, uses real SceneKit rigid bodies, box colliders
and a floor at Y=0. Off objects do not collide; Static objects are obstacles.
Detailed/concave models are approximated by bounding boxes, not exact surfaces.
No cloth, soft-body, fluid or jointed-rig simulation is provided.

Preview never changes authored vertices. **Bake pose to mesh** pauses, asks for
confirmation, and commits the current dynamic-body pose as one undoable geometry
change. It does not create animation keyframes. Reset restores original positions.
Editing/redrawing ends preview; closing the preview window pauses it. Physics
settings are retained in native projects, not OBJ.

## Save and exchange

**Save / Save As** writes `.netvistamodel` projects retaining separate meshes,
colours, masks, physics settings, visibility and transforms. They open from Home, Recent projects (Models
filter), Open, or Finder. Closing or quitting prompts for unsaved changes; app
updates require closing modelling windows first.

**Import OBJ** reads UTF-8 triangular and quad geometry. Source coordinates and
indexed vertices are preserved; OBJ objects are combined into one imported mesh.
UVs, materials, textures, rigs and animations are not imported. Triangulate larger
polygons before importing. No scripts or external material files are executed.

**Export OBJ** exports visible geometry with transforms baked. Use it in Game
Maker, the video editor's 3D Scene importer, Blender or another OBJ-compatible app.
OBJ export here does not include colours/materials; save the native project too.
Game Maker's existing importer normalizes model scale when importing an OBJ.

## Current scope

This is a starter polygon modeller, not Blender feature parity. It does not yet
offer dynamic-topology/remeshing, UV editing, texture painting, booleans, bevels, live modifiers,
multi-object/vertex selection, armature editing, animation, rendering/export of movies, or
`.blend` import. It is currently available in the native Mac app only.

Limits: 256 objects, 250,000 vertices/faces per mesh, 500,000 total vertices/faces,
64 MB OBJ imports and 128 MB native project files. Validation and atomic saves
protect existing documents if an operation fails.

Tests: `ModelingDocumentChecks.swift` checks connected region topology, masks
through extrusion/deletion/subdivision, transforms, imports and save/export
round trips. `ModelingSculptChecks.swift` checks all ten brushes, mask opacity,
erase/invert/protection, unbiased quad normals, symmetry, front-facing protection
and old-project compatibility. `ModelingEditorChecks.swift` exercises native
controls, real Shift-click regions, region actions, mouse-driven sculpt/mask,
stroke undo/cancel, cube-side automatic detail, indexed rendering, helper-plan
atomicity, physics Bake integration, proportional editing and viewport rendering.
It also verifies inspector tabs, loop preview/position/Apply, selection queries,
individual extrusion, contextual disabled actions and one-step loop-cut undo.
Document checks include closed/open quad-strip cuts, winding, interpolated masks,
OBJ round trips and atomic refusal for triangle/budget/invalid-position cases.
`ModelingGeneratorsChecks.swift` covers dragon detail, closed parts and budgets;
`ModelingPhysicsChecks.swift` checks native gravity/collisions and lifecycle;
`ModelingAIChecks.swift` checks opt-in download, SHA-256/size verification, local
installation, cancellation, retry, safe removal and untrusted plans using mocks.
`ModelingAIRuntimeChecks.swift` uses a tiny compiled fixture to test the native
process bridge, fixed arguments, output bounds, timeouts and cancellation.
Actual model inference needs a user download and is not validated by fixtures.
`ModelingToolsChecks.swift` verifies optional-AI controls/no startup requests,
physics transport/close behavior and native utility layouts at small widths.
`StudioHomeChecks.swift`
checks the fourth editor card, routing, filters and responsive layout.

Home artwork is an original procedural SceneKit render. Regenerate with
`Tests/GenerateModelingArtwork.swift`; no third-party image or Blender code is used.
