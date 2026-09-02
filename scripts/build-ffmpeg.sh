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

FLAGS=(
  $LDFLAGS

  # Common
  -I. -I./fftools -I./compat/stdbit -I$BUILD_DIR/include
  -Llibavcodec -Llibavdevice -Llibavfilter -Llibavformat -Llibavresample -Llibavutil -Llibswscale -Llibswresample
  -Wno-deprecated-declarations -Wno-pointer-sign -Wno-implicit-int-float-conversion -Wno-switch -Wno-parentheses -Qunused-arguments
  -lavdevice -lavfilter -lavformat -lavcodec -lswresample -lswscale -lavutil -lm

  # Features
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

  # Goes after `-l -L` switches see: https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/2052
  # there used to be `fftools/ffmpeg.c fftools/ffmpeg_dec.c ...` but the list wen too long already
  $(cd $LIB_PATH && find fftools -name "*.c" ! -name "ffplay.c" ! -name "ffplay_renderer.c" ! -name "ffprobe.c")

  # Emscripten
  -lworkerfs.js
  -s USE_SDL=2
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

if [ "$FFMPEG_LGPL" = false ] ; then
    OUTPUT_FILENAME="$OUTPUT_FILENAME-lgpl"
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
