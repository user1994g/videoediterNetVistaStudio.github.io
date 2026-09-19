# Game Maker — models, characters and visual nodes

Studio Home → **Game Maker** → **2D Game** or **3D Game** opens an empty scene.
This is a native macOS development feature. Other editor windows remain open.

## Import and arrange

- **Import sprites / models…** accepts individual files or folders. Choose the
  whole asset folder to include all textures, material files and supporting files
  in your game save. PNG/JPG images appear as sprites;
  other imported files remain embedded as supporting assets.
- 3D model geometry: OBJ and ASCII/binary STL, plus DAE/SCN and ModelIO-supported
  PLY/USD/USDA/USDC/USDZ formats available on the Mac. Models are triangulated,
  centered, and normalized to one unit. FBX and glTF are not currently supported.
- Select an imported asset, then **Add asset to scene**. The source bytes and a
  portable normalized mesh are embedded; no original file is needed to reopen.
- Models currently use one material. UV coordinates are retained; assign an
  imported image in **Texture**. Source material files are stored when you import
  their folder, but multi-material shading and imported animation clips/skin
  weights are not retained. The Character Rig tools create a new rig.
- **Scene / Layers** selects the object to edit. Duplicate, delete, and ↑/↓ reorder
  objects. Later 2D entries draw in front. Reordering also changes runtime object
  execution order. Each object retains its own node graphs.
- 2D: drag sprites to place them, scroll to pan, Option-scroll to zoom. 3D: click
  the model, edit X/Y/Z and size in Properties, drag to orbit, scroll to zoom.

## Connect visual nodes

1. Select an object and press **+ Event** in the bottom graph panel.
2. Double-click the event (or select it and press **Edit**) to choose Start,
   Every frame, While key held, When key pressed, Timer, or Contact entry.
3. Press **+ Node** to add an action or condition. New nodes are disconnected.
4. Drag a coloured output dot on the right of one node onto the left input dot
   of another. The wire now controls execution. Drag a node body to reposition
   it; double-click to edit its values and target object.
5. Conditions have green **Yes** and red **No** outputs. Connect each to its own
   action chain. Option-click an input dot to remove its incoming wires. Select
   a node and press **Delete** to remove it; deleting the event removes its graph.
6. Scroll to navigate the canvas; pinch to zoom. **Fit** zooms and scrolls to show the graph. The event picker switches between graphs on the selected object.

Actions include keyboard movement, move/rotate per second, set position/size/
opacity, show, hide, destroy, add score, set/add a named variable, walk animation,
stop animation, and animate a sprite sheet. Branches test a held key (including
any movement key), score ≥ value, contact with a target, or named variable ≥ value.
Variables are shared game values, start at zero, and reset on Stop/Play.

Graphs execute in event order, following outgoing wires in creation order,
depth-first. A node executes at most once per event firing; disconnected nodes
never run. Cycles are rejected: use Every frame or Timer for repeating logic.
A target of **This object** acts on the graph's owner. Contact conditions compare
that owner with the chosen target. Contact-entry events fire once on entry;
key-press events fire once per press rather than every frame a key stays down.

Legacy ordered chains retain their behaviour and appear with wires automatically.
Moving nodes, wiring, changing values, deleting and duplicating participate in
Undo/Redo. Graph positions and connections are saved with the object.

## Rig and animate a character

1. Import and place an upright, front-facing humanoid model, preferably in a
   T-pose. Select it and choose **Create humanoid rig** in Properties.
2. Choose a joint from the list. Fit its X/Y/Z position to the body using the
   visible joint dots and bone lines. Positions are in the normalized model's
   local space. The mesh automatically rebinds when you change a joint.
3. **Preview walk** tests the cycle. Set **Cycles / sec** and **Stride °** to tune
   it. Stop the preview to return to the rest pose.
4. **Add movement + walking** creates an editable graph: keyboard movement →
   movement-key condition → Walk on Yes / Stop animation on No.
5. Press **Play** and use WASD or arrows. Esc / Stop restores the authored scene.

This is a starter 16-joint humanoid skeleton with four distance-weighted bone
influences per vertex and a procedural walk cycle. It is real mesh deformation,
not whole-object bobbing. Fit the joints for your model; complex characters still
need artist-authored weights and more advanced tooling. No IK, custom animation
clip editor, imported skeleton playback, gravity or platformer controller is added.

## Animate a sprite

Import and place a sprite-sheet image. In Properties choose **Set up sprite
sheet**, then enter Columns, Rows, Frames and Frames / sec. Frames run left to
right, then top to bottom. **Add movement + animation** creates the same graph
layout as 3D characters, using the Animate sprite sheet node. Releasing the
movement keys stops the animation and restores its first frame. Sprite sheets
also work on sprite planes in a 3D scene.

## Save, play and export

**Save** writes one `.netvistagame` file with scene objects, embedded imported
files, portable model geometry, fitted rigs, sprite-sheet settings, node positions,
and all connections. Saves are atomic. Play owns separate state, so saving during
Play preserves your edited scene. Version-one and version-two projects migrate
when opened; new saves use version three.

**Export game…** still creates a new Three.js or Python/Panda3D source folder.
Static models, sprites, event graphs, conditions and variables export. Character
rigs and sprite-sheet animations currently run only in the native preview: export
explains this limitation before writing any output instead of silently dropping
animation. Save the `.netvistagame` to preserve the full animated project.

The exported README contains setup commands. Three.js requires Node.js; Python
requires its pinned Panda3D dependency. Exports are editable source, not installers.
The local web server binds to 127.0.0.1. Stop/Play or restart resets runtime state.

## Limits and checks

One scene with a fixed game camera. Colliders are axis-aligned boxes; Set position
teleports. No automatic floor, gravity, audio or multiplayer. Up to 2,000 objects,
5,000 embedded files / 128 MB, 100,000 model triangles, 64 events and 64 nodes per
event, 256 wires per event, and 10,000 total action nodes. Undo retains 30 changes.

- `Tests/GameProjectChecks.swift`: portable assets, old-project migration,
  gameplay/collision, malformed data, atomic save/import and source export.
- `Tests/GameGraphChecks.swift`: wire traversal, branches, disconnected nodes,
  variables, key edges, animation commands, invalid graphs/rigs and save/reopen.
- `Tests/GameCanvasChecks.swift`: real mouse-event wiring, node dragging and
  input disconnection.
- `Tests/GameModelChecks.swift`: OBJ/STL import, saved geometry after source
  deletion, real skeletal binding, walking and rest pose.
- `Tests/GameEditorChecks.swift`: both native editors, graph duplication,
  Undo/Redo, Play isolation, character animation, sprite frames and viewport renders.
- `Tests/GameExportChecks.mjs` / `.py`: existing source-runtime behaviour parity.
