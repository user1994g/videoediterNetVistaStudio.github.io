#!/bin/sh
# Build-time dependency acquisition only. This never downloads model weights,
# starts a server, installs a global tool, or runs when the user opens the app.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP=${1:-"$SCRIPT_DIR/NetVista Studio.app"}
COMMIT=1537a0a8b2f8711d840878b0a0677ab2213c882c
SOURCE_SHA=372ba5251b9e1a88cd4dc9127686bf9fdd9fb5820884648e561f5c8c07d4ba34
PATCH_FILE="$SCRIPT_DIR/assets/modeling-ai/licenses/netvista-completion.patch"
LICENSES_DIR="$SCRIPT_DIR/assets/modeling-ai/licenses"
RUNTIME_DIR="$APP/Contents/Helpers/modeling-runtime"
RESOURCE_DIR="$APP/Contents/Resources/modeling-ai"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
    echo "The bundled modeling helper currently builds on Apple Silicon macOS only." >&2
    exit 1
fi

# Keep builds reproducible and isolated. NETVISTA_CMAKE may point at a portable
# CMake unpacked into /private/tmp; no automatic system/Python installation.
CMAKE_BIN=${NETVISTA_CMAKE:-}
if [ -z "$CMAKE_BIN" ]; then CMAKE_BIN=$(command -v cmake || true); fi
if [ ! -x "$CMAKE_BIN" ]; then
    echo "CMake 3.14+ is required to build the bundled helper. Set NETVISTA_CMAKE to its executable." >&2
    exit 1
fi
for REQUIRED_LICENSE in LLAMA-CPP-LICENSE.txt QWEN-LICENSE.txt ATTRIBUTION.txt; do
    if [ ! -f "$LICENSES_DIR/$REQUIRED_LICENSE" ]; then
        echo "Missing modeling AI license resource: $REQUIRED_LICENSE" >&2
        exit 1
    fi
done

WORK_DIR=$(mktemp -d /private/tmp/netvista_model_runtime.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT HUP INT TERM
ARCHIVE=${NETVISTA_MODELING_SOURCE_ARCHIVE:-"$WORK_DIR/source.tar.gz"}
if [ ! -f "$ARCHIVE" ]; then
    echo "Acquiring pinned llama.cpp source for the app build (no model weights)."
    curl --fail --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 180 \
        "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$COMMIT" \
        --output "$ARCHIVE"
fi
ACTUAL_SHA=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL_SHA" != "$SOURCE_SHA" ]; then
    echo "Refusing an unexpected llama.cpp source archive (SHA-256 mismatch)." >&2
    exit 1
fi
tar -xzf "$ARCHIVE" -C "$WORK_DIR"
SOURCE_DIR="$WORK_DIR/llama.cpp-$COMMIT"
if [ ! -f "$SOURCE_DIR/CMakeLists.txt" ]; then
    echo "Pinned source archive did not contain its expected commit directory." >&2
    exit 1
fi
patch --batch --fuzz=0 -p1 -d "$SOURCE_DIR" < "$PATCH_FILE"

SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
"$CMAKE_BIN" -S "$SOURCE_DIR" -B "$WORK_DIR/build" \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
    -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
    -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_NUMBER=11379 \
    -DLLAMA_BUILD_COMMIT="$COMMIT" \
    -DLLAMA_BUILD_COMMON=ON \
    -DLLAMA_BUILD_TOOLS=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DLLAMA_BUILD_APP=OFF \
    -DLLAMA_BUILD_UI=OFF \
    -DLLAMA_TOOLS_INSTALL=OFF \
    -DLLAMA_OPENSSL=OFF \
    -DLLAMA_SUBPROCESS=OFF \
    -DLLAMA_LLGUIDANCE=OFF \
    -DGGML_BACKEND_DL=OFF \
    -DGGML_NATIVE=OFF \
    -DGGML_CPU_ARM_ARCH=armv8-a \
    -DGGML_METAL=OFF \
    -DGGML_ACCELERATE=OFF \
    -DGGML_BLAS=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_OPENMP_FETCH=OFF \
    -DGGML_RPC=OFF \
    -DGGML_LLAMAFILE=OFF
"$CMAKE_BIN" --build "$WORK_DIR/build" --target llama-completion --parallel 4
HELPER="$WORK_DIR/build/bin/llama-completion"

# Fail before installing if the helper requires unbundled non-system dylibs or
# if a future pin silently changes the platform/CLI contract.
lipo -verify_arch arm64 "$HELPER"
otool -L "$HELPER" | awk 'NR > 1 {print $1}' | while IFS= read -r DEPENDENCY; do
    case "$DEPENDENCY" in /usr/lib/*|/System/Library/*) ;; *)
        echo "Unexpected modeling runtime dylib dependency: $DEPENDENCY" >&2; exit 1 ;;
    esac
done
xcrun vtool -show-build "$HELPER" > "$WORK_DIR/platform.txt"
if ! awk '$1 == "minos" && $2 == "11.0" {ok=1} END {exit !ok}' "$WORK_DIR/platform.txt"; then
    echo "The modeling runtime is not built with the required macOS 11 deployment target." >&2
    exit 1
fi
"$HELPER" --help > "$WORK_DIR/help.txt" 2>&1
for FLAG in --model --file --json-schema-file --n-predict --ctx-size --threads \
    --temp --seed --simple-io --no-display-prompt --no-conversation --log-disable --no-perf --offline; do
    if ! grep -F -- "$FLAG" "$WORK_DIR/help.txt" >/dev/null; then
        echo "The pinned runtime does not expose the required argument: $FLAG" >&2
        exit 1
    fi
done
"$HELPER" --version > "$WORK_DIR/version.txt" 2>&1
if ! grep -F "$COMMIT" "$WORK_DIR/version.txt" >/dev/null; then
    echo "The completion helper does not report the pinned build commit." >&2
    exit 1
fi

mkdir -p "$RUNTIME_DIR" "$RESOURCE_DIR"
cp "$HELPER" "$RUNTIME_DIR/llama-completion.pending"
chmod 755 "$RUNTIME_DIR/llama-completion.pending"
mv "$RUNTIME_DIR/llama-completion.pending" "$RUNTIME_DIR/llama-completion"
cp -R "$LICENSES_DIR" "$RESOURCE_DIR/"
cp "$LICENSES_DIR/QWEN-LICENSE.txt" "$RESOURCE_DIR/QWEN-LICENSE.txt"
cp "$WORK_DIR/version.txt" "$RESOURCE_DIR/runtime-version.txt"
cp "$WORK_DIR/platform.txt" "$RESOURCE_DIR/runtime-platform.txt"
echo "Bundled pinned CPU-only modeling runtime for macOS 11 arm64. No model weights downloaded."
