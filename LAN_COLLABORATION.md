# Local collaboration (macOS host beta)

NetVista stays a native desktop application. **Share** starts a local browser
companion for an iPad, phone or another laptop. This is not internet hosting,
screen mirroring, or the complete desktop editor running on an iPad.

## Connect

1. Open a video project on the Mac and press **Share**. Wait for **Sharing**.
2. Connect the other device to the same trusted private LAN. Scan the QR code,
   or copy the **complete HTTP address including its port**, for example
   `http://192.168.2.179:8787/`. The address can change with your network.
3. Enter the temporary six-digit code. It works once and expires after two
   minutes. Press **New Code** for each additional device; paired devices remain
   trusted until **Forget Paired Devices**. Never share codes with strangers.
4. In the companion, choose **Colour** or **3D Scene** and take its editing slot.
   A Colour collaborator and a 3D collaborator can work concurrently. Other
   devices can review until a slot is released. Abandoned slots expire in 30s.
5. **Save your work on the host Mac.** Remote changes are project edits, not a
   separate device copy or automatic cloud backup.

## What works now

- Colour: exposure, contrast, saturation, temperature, tint and vibrance on
  individual timeline video clips. Existing curves, wheels, grade nodes, LUTs,
  effects and animation data are preserved, not replaced by remote commands.
- 3D: move, rotate and scale existing objects; add cubes, spheres, cylinders
  and planes; delete scene objects. Native scene Undo can restore active-scene
  edits. Saved/inactive scene changes use project Undo.
- Preview: the host renders graded clip frames or scene camera frames. Scrub
  and sampled playback use a private per-device preview time, not the shared
  desktop playhead. Preview is deliberately bounded to 960×540 and serial
  decoding; it is not real-time, full-frame-rate streaming. Clip preview shows
  its grade, not the whole composited timeline/effects stack.
- Native edits cause target revisions to advance. Stale remote writes are
  rejected and reloaded. Native unsaved Colour drafts, animated remotely
  controlled properties, active 3D drags/playback and renders are protected.
- Stop Sharing closes connections and editing sessions; reopening another
  project stops sharing and requires an explicit new Share action.

Create/import scenes and models on the Mac first. Full mesh sculpting, rigs,
remote file upload/import, node graphs, full timeline editing and peer-to-peer
native laptop clients are **not included** in this companion beta. Changed 3D
scene data is saved without rendering; rerender its timeline clip on the Mac
when needed, just as in the native scene workflow.

## If the iPad cannot connect

- If Share says **Not sharing** or **Couldn’t start**, use **Restart Sharing**.
  This replaces a failed/waiting listener; New Code alone rotates the code.
- Use `http://`, not `https://`, and include `:8787` (or the displayed fallback
  port). An IP address without a port tries a different server.
- **Check Connection** tests only the Mac. It does not prove iPad access. Watch
  the incoming-connection count while reloading on the other device.
- Zero incoming connections indicates the request did not reach the app.
  Check the browser’s local-network permission, VPN routes and router guest/
  client isolation. The same SSID does not guarantee device-to-device access.
- Allow NetVista in macOS Firewall if prompted; do not disable the firewall.
  Outgoing local self-checks can require Local Network permission independently
  of an incoming TCP listener. Try another trusted network or Personal Hotspot
  if the router isolates devices. Keep the Mac awake with its lid open.

## Trust boundary

The listener accepts private IPv4 LAN peers in the host interfaces' subnets,
plus loopback for diagnostics. It exposes no arbitrary files or native code.
Media routes use only the project's allowlisted asset IDs. Pairing attempts,
connections, request bodies, media streams and preview jobs are bounded.
Editing requires a paired HttpOnly/SameSite cookie, same-origin JSON requests,
an unguessable per-listener anti-CSRF token, a device-bound lease and matching
project/target revisions. Only approved fields are mutated.

**HTTP is not encrypted.** Same-network pairing is not protection from a
malicious network operator. Use this beta only on a trusted private network.
No router port forwarding, cloud tunnel, public exposure or firewall disabling
is necessary or performed by the app. Windows/Linux native hosts do not yet
implement this macOS companion protocol.

## Regression checks

`Tests/ShareCollaborationChecks.swift` is a Foundation-only host protocol test;
compile it with `ShareCollaboration.swift` and `ShareCompanion.swift`. Pass an
existing temporary output directory to generate the browser script, then run
`node Tests/ShareCompanionUIChecks.mjs <output-directory>/companion.js` for pure
client workflow tests without a browser/network. Both tests contain only
disposable fixtures.

Compile `Tests/ShareServerChecks.swift` or
`Tests/ShareCompanionServerChecks.swift` with the three Share server/companion
sources and Cocoa, Network and Security frameworks for actual temporary LAN
listener tests. `Tests/ShareNativeChecks.swift` uses all app sources with
`NETVISTA_STUDIO_TESTING`; it exercises real editor persistence, Undo, protected
drafts, SceneKit JPEG rendering and Share panel layout. Graphics/LAN checks
need macOS access and must not be interpreted as a physical iPad test.
