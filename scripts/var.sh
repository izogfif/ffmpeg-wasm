#!/bin/bash

set -euo pipefail

# Include llvm binaries
export PATH=$PATH:$EMSDK/upstream/bin

ROOT_DIR=$PWD
WASM_DIR=$ROOT_DIR/wasm
BUILD_DIR=$ROOT_DIR/build
EM_PKG_CONFIG_PATH=$BUILD_DIR/lib/pkgconfig
TOOLCHAIN_FILE=$EMSDK/upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake

# `-Og` -> no optimization
# `-g` -> debug info enabled
# `-pthread` restored: the reusable-runtime build uses emscripten pthreads
# (USE_PTHREADS=1 + PROXY_TO_PTHREAD=1). ffmpeg 8's CLI scheduler
# (ffmpeg_sched.c task_start()) pthread_creates its tasks unconditionally, so
# ffmpeg must be compiled WITH pthreads; `-pthread` at link time also enables
# the emscripten pthread flags for the final link.
CFLAGS="-O3 -flto -I$BUILD_DIR/include -pthread -msimd128 -mavx2"

OUTPUT_FILENAME="ffmpeg"
if [ "$FFMPEG_LGPL" = true ] ; then
    OUTPUT_FILENAME="$OUTPUT_FILENAME-lgpl"
else
    OUTPUT_FILENAME="$OUTPUT_FILENAME-gpl"
fi
OUTPUT_PATH=$WASM_DIR/$OUTPUT_FILENAME.js
OUTPUT_PATH_WV=$WASM_DIR/$OUTPUT_FILENAME-wv.js

export CFLAGS=$CFLAGS
export CXXFLAGS=$CFLAGS
export LDFLAGS="$CFLAGS -L$BUILD_DIR/lib"
export EM_PKG_CONFIG_PATH=$EM_PKG_CONFIG_PATH

echo "EMSDK=$EMSDK"
echo "CFLAGS=$CFLAGS"
echo "CXXFLAGS=$CXXFLAGS"
echo "LDFLAGS=$LDFLAGS"
echo "BUILD_DIR=$BUILD_DIR"
