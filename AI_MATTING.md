# Local AI-assisted cutout (macOS beta)

## Use it

1. Select a video clip and open **Effects → Ultra Key**.
2. Enable Ultra Key. Use **Green Screen** or sample your screen colour.
3. Press **Download Model…**, read the explanation and press **Download**.
4. Once installed, enable **AI-assisted person cutout** and set **AI Strength**.
5. Use **Output → Alpha Channel** to inspect the matte. Adjust Tolerance,
   Choke, Soften and Spill, then **Apply to Clip** to save the effect.

Downloading has progress and cancellation. **Remove Model** removes only the
optional model cache, not videos or projects. A saved AI setting does not
download anything when a project opens. If the model is unavailable, preview
uses ordinary chroma key; export asks before using that fallback.
Removal cannot be cancelled once confirmed, and the model cannot be removed
while a timeline export is running. Pending AI settings also stay intact when
adding/removing Effects keyframes; a single undo restores settings and keys.

## What it does

AI identifies the person, protects their interior (including green clothing),
and suppresses non-person surroundings. The chroma matte retains finer detail
near the person silhouette. Strength blends the result with ordinary chroma
key; 0% is ordinary keying. Preview and native timeline export use the same
effect implementation, including transparency, cleanup and spill suppression.

This is **semantic person segmentation**, not a language model or precision
rotoscoping. The model works at 513 × 513, so hair, transparent objects,
occlusions, fast movement and small/distant people can still need manual key
adjustments. Do not enable it to isolate products or other non-person objects.
If no person is detected, the frame falls back to ordinary keying. AI inference
can reduce playback speed, especially on older Macs or when stacking clips.

The underlying chroma key also works without AI: corrected premultiplied-alpha
edges avoid coloured halos, Choke contracts the actual silhouette, Soften
feathers it spatially, and spill suppression also cleans opaque green fringes.

## Download, privacy and source

- The model is Apple's **DeepLabV3 FP16**, 4,342,971 bytes (approximately 4.3 MB).
- The only network operation is the user-requested model download from Apple's
  fixed HTTPS URL. Video frames never leave the computer.
- It installs outside the signed app, in
  `~/Library/Application Support/NetVistaStudio/AIModels/DeepLabV3FP16-v1.3`.
  A receipt and compiled-model cache stay there, separate from project saves.
- The downloader checks HTTP response, exact size, pinned vendor ETag/MD5,
  Core ML input/output schema, person labels and licence metadata. A local
  SHA-256 receipt detects later file changes. The ETag is a corruption/version
  check, not an independently published SHA-256 signature.
- Downloads/installations are cancellable and staged before an atomic install.
  Inference is serialized and preprocessing is bounded even for 16K footage.
- The model identifies the TensorFlow authors and Apache License 2.0. See
  [Apple's model catalogue](https://developer.apple.com/machine-learning/models/)
  and [TensorFlow's licence](https://github.com/tensorflow/tensorflow/blob/master/LICENSE).

The new native modelling and AI cutout features are macOS-only in this beta;
the separate Qt Windows/Linux editor is unchanged. The model is not bundled
with app downloads and has not been installed automatically for testing.
