#!/bin/bash

set -euo pipefail
source $(dirname $0)/var.sh

LIB_PATH=modules/ffmpeg

FLAGS=(
  --target-os=none        # use none to prevent any os specific configurations
  --arch=wasm32
  --cpu=generic
  --enable-cross-compile
  --enable-version3
  --enable-zlib
  --enable-libaom --disable-encoder=libaom_av1
  --enable-libjxl
  --enable-libopenh264
  --enable-libkvazaar
  --enable-libvpx
  --enable-libmp3lame
  --enable-libtheora
  --enable-libvorbis
  --enable-libopus
  --enable-libwebp
  --enable-libsvtav1
  --enable-librubberband
  --enable-libzimg
  --disable-stripping
  --disable-programs      # disable programs build (incl. ffplay, ffprobe & ffmpeg)
  --disable-doc
  --disable-debug
  --disable-runtime-cpudetect
  --disable-autodetect    # disable external libraries auto detect
  --extra-cflags="$CFLAGS"
  --extra-cxxflags="$CXXFLAGS"
  --extra-ldflags="$LDFLAGS"
  --pkg-config-flags="--static"
  --nm=emnm
  --ar=emar
  --ranlib=emranlib
  --cc=emcc
  --cxx=em++
  --objcc=emcc
  --dep-cc=emcc
)

if [ "$FFMPEG_LGPL" = false ] ; then
    FLAGS+=(
        --enable-gpl
        --enable-libx264
        --enable-libx265
    )
fi

sed -i 's/    librubberband//g' $LIB_PATH/configure
sed -i 's/    vapoursynth/librubberband\nvapoursynth/g' $LIB_PATH/configure

# Guarded pthread-types fallback for fftools (kept from the threadless build,
# harmless when pthreads exist): ffmpeg's fftools (ffmpeg.h EncStats.lock,
# ffmpeg_sched.c Scheduler) use pthread types UNCONDITIONALLY, but
# libavutil/thread.h only includes <pthread.h> under HAVE_PTHREADS. With the
# pthreads build enabled (USE_PTHREADS=1) HAVE_THREADS is 1 and the guarded
# block compiles out; if a future build disables pthreads again, Emscripten
# ships pthread.h (types + stub declarations) even in non-pthreads builds, so
# including it on threadless Emscripten keeps fftools compiling.
THREAD_H=$LIB_PATH/libavutil/thread.h
if ! grep -q '__EMSCRIPTEN_PTHREAD_TYPES_FALLBACK__' $THREAD_H; then
    sed -i 's|#include "config.h"|#include "config.h"\n/* __EMSCRIPTEN_PTHREAD_TYPES_FALLBACK__ */\n#if defined(__EMSCRIPTEN__)\n#if !HAVE_THREADS\n#include <pthread.h>\n#endif\n#endif|' $THREAD_H
fi
grep -q '__EMSCRIPTEN_PTHREAD_TYPES_FALLBACK__' $THREAD_H || { echo "thread.h pthread fallback patch failed"; exit 1; }

# Reusable-runtime state reset (REQUIRED: run #2 must not see run #1's registered
# inputs — the -wv module runs callMain() many times; ffmpeg's
# fftools keep process-global state that a fresh process would re-initialize).
# ffmpeg_cleanup() frees the arrays but never resets the counters, so a second
# run would register its input as file #1 and break `-map 0:...` etc.
FFMPEG_C=$LIB_PATH/fftools/ffmpeg.c
if ! grep -q '__WASM_REUSABLE_RUNTIME_RESET__' $FFMPEG_C; then
    python3.11 - "$FFMPEG_C" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
needle = "    term_exit();\n    ffmpeg_exited = 1;\n}"
ins = ("    term_exit();\n"
       "    ffmpeg_exited = 1;\n"
       "    /* __WASM_REUSABLE_RUNTIME_RESET__ */\n"
       "    /* The wasm module is reused across callMain() runs; ffmpeg_cleanup runs at\n"
       "     * the end of every run, so reset the process-global fftools state that a\n"
       "     * fresh process would re-initialize. */\n"
       "    nb_filtergraphs = 0;\n"
       "    nb_output_files = 0;\n"
       "    nb_input_files = 0;\n"
       "    nb_decoders = 0;\n"
       "    atomic_store(&transcode_init_done, 0);\n"
       "    ffmpeg_exited = 0;\n"
       "}")
assert s.count(needle) == 1, 'ffmpeg_cleanup tail not found exactly once'
s = s.replace(needle, ins, 1)
open(p, 'w').write(s)
print('patched', p)
PYEOF
fi
grep -q '__WASM_REUSABLE_RUNTIME_RESET__' $FFMPEG_C || { echo "ffmpeg.c reusable-runtime reset patch failed"; exit 1; }

echo "FFMPEG_CONFIG_FLAGS=${FLAGS[@]}"
(cd $LIB_PATH && \
    PKG_CONFIG_PATH=$PWD/build/lib/pkgconfig && \
    emconfigure ./configure "${FLAGS[@]}")
