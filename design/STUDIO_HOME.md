# Studio Home — artwork-led native launcher

## Design direction

Use the attached concept as the visual specification, not as a bitmap UI.
Two photographic editor tiles are the primary actions. A quiet, fixed sidebar
keeps Home and Recent projects available. Recent documents are real files from
the macOS document registry, with All / Video / Photos filters and search.
Preserve the user's logo and separate editor windows; never reset an open project.

## Research

- [Adobe Photoshop Home screen overview](https://helpx.adobe.com/uk/photoshop/desktop/get-started/learn-the-basics/homescreen-overview.html) (updated 2 December 2025): create/open, recent documents, filtering, Home accessible from the workspace.
- [Adobe Creative Cloud desktop Home](https://helpx.adobe.com/ca/creative-cloud/help/ccd-app-home-screen.html) (updated 21 October 2022): app launching and return to recent work.

These inform navigation, not copied Adobe branding, artwork, or code.

## Implementation specification

- AppKit, not HTML or a webview. Existing document/editor callbacks retained.
- Native macOS title bar, then 52 pt brand bar; 192 pt fixed sidebar.
- Near-black sidebar #141517; charcoal content #1B1C1F; panel #25262A.
- Text #F0F0F2; secondary #A5A8AE; restrained NetVista red #F34C53.
- SF system type: 28 pt welcome heading, 19–21 pt editor titles, 12–13 pt body.
- Content centered, maximum width 1240 pt, 28–40 pt margins, 20 pt tile gutter.
- Artwork cropped proportionally; never stretched; 8 pt tile corners.
- White editor buttons; outlined Open project; red tick on active navigation.
- At narrow widths, move tile buttons below descriptions. Only the main area
  scrolls vertically; sidebar remains visible. No horizontal overflow.
- Fully working editor actions, project picker, recent file search/filter,
  unavailable-file feedback and a concise Quick guide.
- Recent empty state must not invent sample projects or counts.
- Bundled artwork: assets/home-video-coast.png and assets/home-photo-petals.png.
- Concept: design/studio-home-concept.png.

## Image generation provenance and final prompts

Created using the built-in image-generation tool, not Photoshop. Original
generated files are preserved. Text and controls in the app are native live UI;
the two artwork files contain no baked-in controls or text.

### Mockup

Use case: ui-mockup
Asset type: high-fidelity native macOS application welcome screen, 1440 x 1000 landscape. One complete flat front-facing app window, not photographed on a device. This is the final design specification to implement in code.
Primary request: Design NetVista Studio's creative application launcher with the maturity of Adobe Creative Cloud / Photoshop Home. Be original, editorial, visually confident, exceptionally polished, practical desktop UI. No website hero, no giant slogans, no dashboard analytics, no generic SaaS gradients. Dense enough to feel like real desktop software yet generous spacing.
Layout: full-width slim 52px title bar. NetVista Studio brand at top left with a tiny red square brand accent; "Public beta" subtle at top right. Below it a quiet 192px near-black left sidebar with Home (selected with subtle red tick and lighter rectangular fill), Recent projects, horizontal divider, small "WORKSPACES", Video Editor, Photo Editor, and bottom "Quick guide", "Version 1.4.0". Main surface warm charcoal #1a1b1e, not blue. Main padding 44px.
Main content: heading "Welcome to your studio." about 30px white semibold, subtitle "Open an editor or pick up where you left off." 13px muted gray. Top right a small outlined "Open project..." button.
Below, two equally wide beautifully art-directed app launch tiles, separated by 20px. Each about 430px wide by 340px high. Upper 215px is edge-to-edge photographic artwork: left a cinematic high-angle winding coastal road on dramatic rust-colored cliffs overlooking dark teal sea, small vehicle, late sunlight, subtle film grain. Right a very close editorial macro photograph of sculptural coral-red flower petals with electric blue/violet rim light against deep black, elegant organic texture. Subtle 8px corner radius. Bottom 120px of tiles is solid #25262a containing small film/photo icon, title "Video Editor" / "Photo Editor" in 21px semibold, short one-line description "Timeline, colour, sound & 3D." / "Layers, brushes & retouching." and a small light solid button "Open editor" at bottom right. One subdued category label CINEMA / IMAGES may overlay upper-left of artwork. No fake play buttons embedded in art.
Below tiles: "Recent projects" heading, compact All / Video / Photos filters, a right-aligned search field. Empty state bordered with thin gray line, small folder icon and text "A fresh start." and "Your saved projects will appear here." plus simple "Open a project" link. No fake recent files or example thumbnails, no counters or cloud services.
Exact useful text only. Use consistent SF Pro / Adobe Clean-like sans serif with clean hierarchy, precise iconography and pixel-aligned spacing. Strong readable contrast, fine separators, restrained red NetVista accent. Make image feel like a shippable professional application, not a wireframe or marketing website. Do not include Adobe branding or logos.

### Video tile

Production photographic artwork for NetVista Studio native app launch tile. Wide landscape 3:2 composition. Cinematic high-angle view of a winding coastal road cut into tall rust-gold cliffs above dark teal ocean, one small dark car on a bend, late afternoon sidelight, receding misty headlands, elegant natural film grain. Realistic cinematic still, rich warm cliffs against cool water, no oversaturation. Scene fills frame, road curves center-left, ocean on right. No text, no letters, no logos, no UI, no border. Match sophisticated editorial photography for a video editor home screen.

### Photo tile

Production photographic artwork for NetVista Studio native app launch tile. Wide landscape 3:2 composition. Extreme macro editorial studio photograph of sculptural flowing red and coral poppy petals, ridged organic velvety texture, dramatic electric blue/violet rim light catching curled edges, deep nearly black background. One large petal sweeping diagonally across foreground, additional red petals behind, exquisite close focus texture, elegant rich contrast, no oversaturation. Photographic not 3D plastic. No text, no letters, no logos, no UI, no borders. Art directed for a professional photo editor home screen.

