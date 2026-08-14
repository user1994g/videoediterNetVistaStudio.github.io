# NetVista Studio Mods v1

NetVista Studio 1.3 introduces portable, data-only `.netvistamod` packages. One package can be installed on macOS, Windows, or Linux without putting files inside the application itself.

Mods v1 may provide themes, declarative pages, 3D prop/map descriptions, and effect presets. They cannot contain or execute JavaScript, Python, Swift, shell scripts, executables, native libraries, web pages, shader source, or another archive. This keeps installing a visual mod from silently becoming permission to run a stranger's program.

## Install a mod

Open the **Mods** page and drop a `.netvistamod` file onto it, or use **Install Mod…**. A newly installed mod is disabled until the user explicitly enables it. The page also has **Open Mods Folder** for packages copied by hand.

Mods survive application updates because they are stored per user:

- macOS: `~/Library/Application Support/NetVista Studio/Mods`
- Windows: `%APPDATA%\NetVista Studio\Mods`
- Linux: `$XDG_DATA_HOME/netvista-studio/mods`, or `~/.local/share/netvista-studio/mods`

## Package layout

A `.netvistamod` file is a ZIP archive with `mod.json` at the archive root. Do not place everything inside an extra wrapper folder.

```text
my-city-tools.netvistamod
├── mod.json
├── themes/
│   └── night.json
├── pages/
│   └── city-builder.json
├── scene-props/
│   └── streetlamp.json
├── scene-maps/
│   └── downtown.json
├── effect-presets/
│   └── neon.json
├── assets/
│   └── lamp.usdz
└── docs/
    └── readme.txt
```

Every payload file must be declared by `integrity.files`, and every declared file must exist. Paths are relative, use `/`, and may not contain `..`, absolute paths, links, case-folded duplicates, or hidden executable content.

## Manifest

```json
{
  "schemaVersion": 1,
  "modAPI": "1.0",
  "id": "com.creator.citytools",
  "name": "City Tools",
  "version": "1.0.0",
  "publisher": {
    "name": "Creator Name",
    "website": "https://example.com"
  },
  "description": "A night theme and reusable city assets.",
  "minAppVersion": "1.3.0-beta.1",
  "maxAppVersion": "2.0.0",
  "capabilities": ["theme", "page", "sceneProp", "sceneMap", "effectPreset"],
  "dependencies": [],
  "content": {
    "themes": ["themes/night.json"],
    "pages": ["pages/city-builder.json"],
    "sceneProps": ["scene-props/streetlamp.json"],
    "sceneMaps": ["scene-maps/downtown.json"],
    "effectPresets": ["effect-presets/neon.json"]
  },
  "integrity": {
    "algorithm": "sha256",
    "files": {
      "themes/night.json": "REPLACE_WITH_64_HEX_SHA256",
      "pages/city-builder.json": "REPLACE_WITH_64_HEX_SHA256",
      "scene-props/streetlamp.json": "REPLACE_WITH_64_HEX_SHA256",
      "scene-maps/downtown.json": "REPLACE_WITH_64_HEX_SHA256",
      "effect-presets/neon.json": "REPLACE_WITH_64_HEX_SHA256",
      "assets/lamp.usdz": "REPLACE_WITH_64_HEX_SHA256",
      "docs/readme.txt": "REPLACE_WITH_64_HEX_SHA256"
    }
  }
}
```

Use a stable reverse-domain ID that you control. Versions use semantic versioning. Integrity hashes detect damaged or replaced files; they do not prove a publisher's identity, so packages are shown as creator content rather than NetVista-signed code.

## Themes

A theme can change a bounded set of Studio colours and corner radius. It cannot import CSS, fonts, images, selectors, or code.

```json
{
  "schemaVersion": 1,
  "id": "night",
  "name": "City Night",
  "tokens": {
    "windowBackground": "#0B0D12",
    "topBarBackground": "#07090D",
    "panelBackground": "#141821",
    "workspaceBackground": "#0F1218",
    "cardBackground": "#19212C",
    "controlBackground": "#222B37",
    "primaryText": "#F4F6FA",
    "secondaryText": "#9BA8B8",
    "accent": "#FF3945",
    "danger": "#FF5964",
    "separator": "#344051",
    "cornerRadius": 7
  }
}
```

Colours must be `#RRGGBB` or `#RRGGBBAA`; corner radius must be from 0 through 16.

## Declarative pages

Pages are rendered by NetVista Studio from a small native block format. They never embed a browser or run creator code.

```json
{
  "schemaVersion": 1,
  "id": "city-builder",
  "title": "City Builder",
  "summary": "Add the pack's maps and props to a scene.",
  "blocks": [
    {"kind": "heading", "title": "City Builder"},
    {"kind": "text", "text": "Start a scene, then choose a map or prop."},
    {"kind": "button", "title": "Open 3D Scene", "action": "open3DScene"},
    {"kind": "button", "title": "Show City Assets", "action": "showCatalog", "arguments": {"id": "city"}},
    {"kind": "button", "title": "Creator Website", "action": "openURL", "arguments": {"url": "https://example.com"}}
  ]
}
```

Supported blocks are `heading`, `text`, `image`, `divider`, and `button`. Actions are restricted to NetVista Studio commands: `importMedia`, `open3DScene`, `openModsFolder`, `showCatalog`, and an explicitly clicked HTTPS `openURL`.

## Catalog documents

Files in `scene-props`, `scene-maps`, and `effect-presets` use a common descriptive envelope. In Mods v1 these entries form a checked, viewable catalog; they are not automatically inserted into a scene or applied to a clip yet. `asset` is a relative file from the same package and `parameters` contains finite descriptive numeric values for a future built-in importer.

```json
{
  "schemaVersion": 1,
  "id": "streetlamp",
  "name": "Street Lamp",
  "summary": "A reusable lamp for night scenes.",
  "asset": "assets/lamp.usdz",
  "parameters": {
    "scale": 1.0
  }
}
```

## Build the package

1. Create the folders and JSON documents.
2. Calculate SHA-256 for every payload file and put the lowercase 64-character values in `mod.json`.
3. ZIP the *contents* of the package folder so `mod.json` is at the archive root.
4. Rename the ZIP from `.zip` to `.netvistamod`.
5. Install it on the Mods page. Test disabled, enabled, app restart, project reopen, and removal states before sharing it.

For a future executable plug-in API, NetVista Studio will need a separate permission model, sandboxed helper process, signing/identity system, crash isolation, and cross-platform API. Mods v1 intentionally does not claim those safety guarantees yet.
