# Optional local modeling helper

The 3D Editor works without AI. Native starters, manual mesh editing, sculpt
brushes, detail levels and physics are independent of the optional model.

The **AI Helper** is an experimental text-to-*plan* helper. It can suggest
native shapes, a sculptable dragon starter, and controlled subdivision or
smoothing. It does not generate finished arbitrary meshes, rigs, textures or
Blender-quality characters from text. Continue sculpting the proposed shapes.

## Download and use

1. Open **3D Editor → Local AI helper…**.
2. Choose **Download model…** and approve the source/size prompt, or choose
   **Not now**. There is no preliminary Check step or separate Ollama install.
3. NetVista downloads **Qwen2.5 0.5B Instruct Q4_K_M**, about **491 MB**, into
   your Application Support folder. Progress is shown; you can cancel or retry.
4. A complete size/SHA-256 check must pass before the status becomes ready.
5. Enter a short request, press **Ask local AI**, review the suggested plan,
   then press **Apply Plan**. Applying is one undoable operation.

The model remains installed across app launches. Existing files are checked
locally in the background; starting the app or opening a project never downloads
anything. **Check installation** only reads local files. **Remove model…**
removes just this optional model after confirmation, preserving your projects,
other AI models, and all manual modeling features.

A small model can suggest imperfect plans. Unsupported, incomplete or oversized
output is rejected, not executed as code. A changed scene/selection invalidates
an earlier proposal so it cannot apply to the wrong model.

## Privacy, storage and memory

- Download is the only network action. A fixed revision/file from Qwen's official
  Hugging Face repository is used; HTTPS redirects are restricted to approved
  Hugging Face download hosts, and a pinned SHA-256 is always verified.
- Downloads stream directly to a unique pending file, not a 491 MB RAM buffer.
  Incomplete or corrupt files never become ready. Cancelled downloads are cleaned
  up and a retry starts a fresh transfer, not an unverified partial install.
- The saved model is in
  ~/Library/Application Support/NetVistaStudio/AIModels/Qwen2.5-0.5B-Q4_K_M-v1/.
  A receipt records the pinned size/digest. Files and storage directory links are
  refused; installation is an atomic same-volume rename.
- Inference uses the signed CPU-only llama.cpp helper included in the Mac app.
  No Ollama, localhost server, global install, login item or cloud account is
  needed. Its fixed invocation uses offline mode, isolated options/environment
  and an explicit local model file; no prompt is sent to a remote API.
- Only the text request and a small scene summary (object count and selected
  mesh name/vertex/face counts) are passed to that local process. Geometry,
  screenshots, images and video are never uploaded.
- Download size is not total RAM use. Inference needs additional memory. Context,
  generation, thread count and output are bounded; the process exits after every
  proposal or cancellation so its model memory is released.

## Validation boundaries

Only addPrimitive, dragonStarter, subdivideSelected and smoothSelected
are accepted. Known primitives, transforms, colors, scene capacity and aggregate
detail/smoothing counts are validated. The editor then checks geometry budgets
before applying the entire plan atomically. Unknown fields, scripts, commands,
URLs and external assets are never modeling tools.

Prompts and the JSON schema are written as literal data to private temporary
files, not interpolated into shell commands. The helper receives fixed process
arguments; output is bounded, both pipes are drained, and generation has a
timeout/cancel path. Temporary prompt/schema files are removed before completion.

Offline tests use tiny synthetic download fixtures and a compiled process
fixture. They verify the transport, installation and native process bridge,
not real-model generation quality. Actual inference still requires an explicitly
approved model download; no real weights are fetched by automated tests.

## Sources and licenses

[Qwen's official GGUF model](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF)
is released under Apache License 2.0. [llama.cpp](https://github.com/ggml-org/llama.cpp)
is MIT-licensed. Runtime/model licenses and attribution are included in the
app's resources. The app bundles a small CPU runtime, **not** the model weights.

build_modeling_runtime.sh pins and verifies the upstream runtime source,
builds only the completion helper for macOS 11/Apple Silicon, and disables
servers, GPU code and dynamic backend loading. A small recorded source patch
isolates configuration and makes stdout contain only generated token data.
HTTP utility code exists transitively in upstream; NetVista does not expose
remote model arguments and always invokes the helper in offline mode. The app
build signs the helper as well as the main executable.

This helper is separate from the Video Editor's optional person-segmentation
model; downloading one does not silently install the other.

## Building the Mac app

Install CMake 3.14+ in your development environment, then run `sh build_app.sh`
from the source folder. If using a portable CMake, set `NETVISTA_CMAKE` to its
executable. The build fetches only the pinned runtime source (about 36 MB),
verifies its archive digest, applies the recorded patch and builds the 9.2 MB
helper. Temporary source/build files are cleaned automatically. It never fetches
the 491 MB model weights.

For an offline build, also set `NETVISTA_MODELING_SOURCE_ARCHIVE` to a previously
verified source archive. A different digest is refused. CMake and the source
archive are developer build dependencies, not installations required on the
computers of people downloading the finished app.
