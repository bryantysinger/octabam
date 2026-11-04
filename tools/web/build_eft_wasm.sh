#!/usr/bin/env bash
# elektron-firmware-tool (vendor/, with tools/patches/elektron-firmware-tool.patch)
# -> docs/site/builder/eft.mjs + eft.wasm, the module the web builder runs on
# an in-memory filesystem. Needs emcc on PATH (emsdk).
set -euo pipefail
cd "$(dirname "$0")/../.."
src=vendor/elektron-firmware-tool
out=docs/site/builder
command -v emcc >/dev/null || { echo "emcc not on PATH (source emsdk_env.sh)" >&2; exit 1; }
emcc -O2 -o "$out/eft.mjs" "$src"/main.c "$src"/compress.c "$src"/decompress.c "$src"/integrity.c \
  -sMODULARIZE -sEXPORT_ES6 -sENVIRONMENT=web,worker,node -sFORCE_FILESYSTEM \
  -sEXPORTED_RUNTIME_METHODS=FS,callMain,ENV -sINVOKE_RUN=0 -sALLOW_MEMORY_GROWTH=1
