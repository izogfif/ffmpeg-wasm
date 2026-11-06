#!/bin/bash

set -eo pipefail
source $(dirname $0)/var.sh

LIB_PATH=modules/ffmpeg
INFO_FILE=$WASM_DIR/$OUTPUT_FILENAME.txt

mkdir -p $WASM_DIR

# In ffmpeg 8.0.0, fftools/resources/resman.c expects `extenrn const ...` made out of .css and .html files.
# Not usre if this is needed for wasm runtime, but I can not figure out way to remove it in build time.
# AI suggested to use xxd
(cd $LIB_PATH/fftools/resources && xxd -n ff_graph_css_data -i graph.css > graph.css.c)
(cd $LIB_PATH/fftools/resources && xxd -n ff_graph_css -i graph.css >> graph.css.c)
(cd $LIB_PATH/fftools/resources && xxd -n ff_graph_html_data -i graph.html > graph.html.c)
(cd $LIB_PATH/fftools/resources && xxd -n ff_graph_html -i graph.html >> graph.html.c)

# ---------------------------------------------------------------------------
# Variant-dependent link inputs.
#
# The LGPL variant links ONLY libopus (BSD) and zlib (zlib license). The link
# list — not configure — is what decides what code physically lands in
# ffmpeg-lgpl.wasm: an archive referenced by -l but never pulled in by the
# linker adds no code, but emscripten's linker-graph still includes its
# referenced objects, so the ONLY way to guarantee the artifact contains no
# GPL code (libx264, libx265, rubberband, ...) is to not reference it at all.
#
# The GPL variant keeps the EXACT original flag list (including -lavdevice
# and -s USE_SDL=2, both dead weight: fftools/ffmpeg.c never calls
# avdevice_register_all() and the only SDL user, ffplay_renderer.c, is
# excluded from the link). The order of every flag in the GPL variant is
# byte-identical to the pre-census script so that the rebuilt
# ffmpeg-gpl.wasm stays hash-identical to the tested build (backup:
# D:\intersub-4830\ffmpeg-wasm-backup-261106-01\wasm\,
# sha256 d10200b794d539e86860143cc3acab63d8789747af2ad15bff92cdb72455b239).
# ---------------------------------------------------------------------------
if [ "$FFMPEG_LGPL" = false ] ; then
    DEVICE_LIB=(-lavdevice)
    SDL_FLAG=(-s USE_SDL=2)
    EXTERNAL_LIBS=(
        -laom
        -lSvtAv1Enc -LSvtAv1Enc -Llibstvav1
        -lopenh264
        -lkvazaar
        -lvpx
        -lmp3lame
        -lvorbis -lvorbisenc -lvorbisfile
        -logg
        -ltheora -ltheoraenc -ltheoradec
        -lz
        -lopus
        -lwebp -lwebpmux -lsharpyuv
        -lrubberband -lsamplerate -Lrubberband -Lsamplerate
        -ljxl -ljxl_cms -ljxl_threads -lhwy -lbrotlienc -lbrotlidec -lbrotlicommon
        -lzimg
    )
else
    # -lavdevice and -s USE_SDL=2 removed for the LGPL variant (D5). This
    # works because the LGPL configure passes --disable-avdevice: with
    # CONFIG_AVDEVICE=0, fftools' #if CONFIG_AVDEVICE references (ffmpeg.c
    # avdevice_register_all, opt_common.c device listing + PRINT_LIB_INFO)
    # compile out and the link genuinely needs no -lavdevice. (Without
    # --disable-avdevice the link fails with undefined avdevice_* symbols.)
    # USE_SDL=2 is only consumed by ffplay_renderer.c, which is excluded.
    DEVICE_LIB=()
    SDL_FLAG=()
    EXTERNAL_LIBS=(
        -lz
        -lopus
    )
fi

FLAGS=(
  $LDFLAGS

  # Common
  -I. -I./fftools -I./compat/stdbit -I$BUILD_DIR/include
  -Llibavcodec -Llibavdevice -Llibavfilter -Llibavformat -Llibavresample -Llibavutil -Llibswscale -Llibswresample
  -Wno-deprecated-declarations -Wno-pointer-sign -Wno-implicit-int-float-conversion -Wno-switch -Wno-parentheses -Qunused-arguments
  "${DEVICE_LIB[@]}" -lavfilter -lavformat -lavcodec -lswresample -lswscale -lavutil -lm

  # Features
  "${EXTERNAL_LIBS[@]}"

  # Goes after `-l -L` switches see: https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/2052
  # there used to be `fftools/ffmpeg.c fftools/ffmpeg_dec.c ...` but the list wen too long already
  $(cd $LIB_PATH && find fftools -name "*.c" ! -name "ffplay.c" ! -name "ffplay_renderer.c" ! -name "ffprobe.c")

  # Emscripten
  -lworkerfs.js
  "${SDL_FLAG[@]}"
  -s WASM_BIGINT
  -s MALLOC=mimalloc                   # available since 3.1.50
#  -s EXPORT_ES6=1                     # https://github.com/emscripten-core/emscripten/issues/22508
#  -s STRICT=1                         # 3.1.65 wasm-ld: error: lto.tmp: undefined symbol: __syscall_geteuid32
  -s INVOKE_RUN=0
  -s EXIT_RUNTIME=0                    # keep the runtime alive across runs (reusable module); no exitRuntime()/PThread teardown is emitted
  -s MODULARIZE=1
  -s EXPORT_NAME="createFFmpeg"
  -s EXPORTED_FUNCTIONS="[_main, ___wasm_init_memory_flag]"
  -s EXPORTED_RUNTIME_METHODS="[callMain, FS, HEAPU32, WORKERFS, runtimeKeepalivePush, runtimeKeepalivePop]"

                                        # emcripten 6.0.2 requires listed all that goes into createFFmpeg({...
  -s INCOMING_MODULE_JS_API="[locateFile, mainScriptUrlOrBlob, onExit, printErr, stderr, stdin, stdout, wasmMemory]"
  -s INITIAL_MEMORY=96mb
  -s ALLOW_MEMORY_GROWTH=1
  -s MAXIMUM_MEMORY=4gb
  -s ENVIRONMENT=worker
  -s PROXY_TO_PTHREAD=1                # REQUIRED with ffmpeg 8's CLI scheduler: main() runs on an internal em-pthread
                                       # ("Application main thread", spawned per callMain by _emscripten_proxy_main), so the
                                       # module-hosting worker's event loop stays free to service the scheduler's
                                       # SYNC-proxied nested pthread_create/FS calls mid-run. Without it (synchronous
                                       # callMain) every audio-batch run deadlocked at the first nested spawn.
                                       # Per-run completion signal: Module.onExit(status) fires on the hosting worker
                                       # (real ffmpeg exit code: 0 success / 1 ffmpeg error) via the 5th -wv patch.
  -s STACK_SIZE=5MB                     # required since 3.1.27 (Uncaught Infinity runtime error)
  -s DEFAULT_PTHREAD_STACK_SIZE=2MB     # required since 3.1.27 (Uncaught Infinity runtime error)
  -o $OUTPUT_PATH
                                        # Pthreads build (restored after the threadless rebuild proved ffmpeg 8 cannot
                                        # transcode without the scheduler's real threads: `pthread_create() failed:
                                        # Not supported`, exit -138 — see doc/reusable-runtime-build.md Addendum 2).
                                        # The reusable runtime survives between runs: EXIT_RUNTIME=0 (no exitRuntime
                                        # emitted) + the 5th -wv patch (persistent-runtime core) keeps the em-pthread
                                        # pool alive across callMain() runs and recycles the finished main pthread.
  -s USE_PTHREADS=1
  -s PTHREAD_POOL_SIZE_STRICT=0         # don't hard-error when the pthread pool is exhausted; spawn on demand
                                        # IMPORTED_MEMORY=1: keep the wasm importing `env.memory` so the wrapper can
                                        # hand the module its own (shared) WebAssembly.Memory. With pthreads the
                                        # import descriptor is shared-compatible: flags=2 (max|shared), min=1536
                                        # (96mb), max=65536 (4gb) — the player's
                                        # new WebAssembly.Memory({initial: 2048, maximum: 65536, shared: true}) is accepted.
  -s IMPORTED_MEMORY=1
  -s ASSERTIONS=1
)

# NOTE: the old `if [ "$FFMPEG_LGPL" = false ]` block that appended -lx264
# -lx265 (and reassigned OUTPUT_FILENAME) is reconstructed below; the
# OUTPUT_FILENAME reassignment was dead code (OUTPUT_PATH/_WV were already
# computed by var.sh and INFO_FILE by the top of this script) and was dropped.
if [ "$FFMPEG_LGPL" = false ] ; then
    FLAGS+=(
        -lx264
        -lx265
    )
fi

echo "FFMPEG_EM_FLAGS=${FLAGS[@]}"
(cd $LIB_PATH && \
    emmake make -j$(nproc) && \
    emcc "${FLAGS[@]}")

echo "emcc ${FLAGS[@]}" > $INFO_FILE
echo "" >> $INFO_FILE

git config --get remote.origin.url >> $INFO_FILE
git rev-parse HEAD >> $INFO_FILE
echo "" >> $INFO_FILE

echo "EMCC (emcc -v)" >> $INFO_FILE
emcc -v &>> $INFO_FILE
echo "" >> $INFO_FILE

git submodule foreach 'git config --get remote.origin.url && git rev-parse HEAD && echo ""' >> $INFO_FILE
