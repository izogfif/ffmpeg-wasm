#!/bin/bash

set -euo pipefail
source $(dirname $0)/var.sh

LIB_PATH=modules/ffmpeg

# NOTE: --disable-everything is NOT here; it is the head of the LGPL
# variant's component list and must come BEFORE every --enable-* component
# flag (configure processes options in order: enables issued before
# --disable-everything are wiped, enables after it survive).
FLAGS=(
  --target-os=none        # use none to prevent any os specific configurations
  --arch=wasm32
  --cpu=generic
  --enable-cross-compile
  --enable-version3
)

# GPL variant: the external-library block sits exactly where the pre-census
# script had it (right after --enable-version3), so the GPL variant's flag
# order is byte-identical to the tested build's configuration.
if [ "$FFMPEG_LGPL" = false ] ; then
    FLAGS+=(
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
    )
fi

FLAGS+=(
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
else
    # ------------------------------------------------------------------
    # LGPL variant: --disable-everything + census contract.
    #
    # External libraries: ONLY libopus (BSD) and zlib (zlib license).
    # Every census component below is native in-tree ffmpeg code (LGPL),
    # verified against the wide-video/ffmpeg checkout in modules/ffmpeg
    # (160737cf0d, 8.0.git): the native aac encoder is not GPL-gated and
    # not experimental; the native vorbis/theora/opus/ass/ssa decoders do
    # not require libvorbis/libtheora/libopus/libass; the png encoder needs
    # zlib only.
    #
    # --enable-gpl is deliberately absent in this variant.
    # ------------------------------------------------------------------
    FLAGS+=(
        --disable-everything

        # libavdevice ON (player extension): the player's silence-synthesis
        # runs `-f lavfi -i anullsrc=...` and `lavfi` is NOT a libavformat
        # demuxer in this tree — it is lavfi.indev (CONFIG_LAVFI_INDEV,
        # libavdevice/Makefile:35), registered as the "lavfi" demuxer by
        # avdevice_register_all() (libavdevice/alldevices.c:45,67). So the
        # LGPL variant keeps CONFIG_AVDEVICE=1 (it lives in LIBRARY_LIST,
        # which --disable-everything does not touch), enables the lavfi
        # indev below, and links -lavdevice (build-ffmpeg.sh). libavdevice
        # is an LGPL library; the only object compiled into it under this
        # census is lavfi.o (+alldevices.c) — no SDL, no platform devices.
        # (With --disable-avdevice the same link would fail on undefined
        # avdevice_* symbols: fftools' #if CONFIG_AVDEVICE references
        # compile in whenever the library is on.)
        "--enable-indev=lavfi"    # lavfi_demuxer (alldevices.c): `-f lavfi -i ...`

        # External libraries (survive --disable-everything: they live in
        # EXTERNAL_LIBRARY_LIST / EXTERNAL_AUTODETECT_LIBRARY_LIST, not in
        # COMPONENT_LIST)
        "--enable-zlib"
        "--enable-libopus"

        # Protocols: --disable-everything also unsets PROTOCOL_LIST, so the
        # file protocol MUST be re-enabled for WORKERFS I/O (file.c goes
        # through POSIX open() which the Emscripten FS/WORKERFS implements).
        # pipe is required for the player's lane decode `-f nut -`: the CLI
        # rewrites the bare `-` filename to `pipe:` (ffmpeg_opt.c:1511,
        # ffmpeg_mux_init.c:3308) and the pipe protocol is the same file.c
        # code path (fd 0/1), so it costs nothing extra.
        "--enable-protocol=file,pipe"

        # Demuxers. NOTE: 'webm' is NOT a demuxer component in this tree —
        # webm input is handled by the matroska demuxer (runtime name
        # "matroska,webm", matroskadec.c:5037); the census line "matroska
        # webm" is therefore satisfied by matroska alone.
        "--enable-demuxer=matroska,mov,avi,asf,ogg,aac,ac3,eac3,dts,mp3,flac,truehd"

        # Muxers (remux targets for the census inputs + image2 for the
        # png/rawvideo frame-extraction path). NOTE: m4a/3gp/3g2/mj2 are
        # runtime aliases of the mov/mp4 muxers, NOT configure components
        # (verified against allformats.c); the real components are those
        # listed here.
        # Player extension: nut (lane decode `-f nut -` stdout), segment
        # (audio batch `-f segment -segment_times`), ass (raw ASS copy
        # `-c:s copy -f ass`), webvtt (subtitle extract `-f webvtt`),
        # pcm_s16le (STT `-f s16le` — runtime name "s16le", pcmenc.c PCMDEF).
        "--enable-muxer=matroska,webm,mov,mp4,ipod,psp,ogg,adts,wav,image2,image2pipe,null,nut,segment,ass,webvtt,pcm_s16le"

        # Video decoders. NOTE: the msmpeg4v3 decoder's runtime listing name
        # is "msmpeg4" (msmpeg4dec.c:908); the configure component is
        # msmpeg4v3.
        # Player extension: h264 (sample + most lane inputs), vp8/vp9/av1
        # (webm lanes), mpeg2video/mpeg1video (mpg/VOB files), mjpeg
        # (thumbnail backfill reads), wmv3/vc1 (WMV9 files, per the
        # requester). All native in-tree LGPL decoders — no libvpx/libaom.
        # wrapped_avframe: the lavfi indev's video output codec (the OCR
        # lane's `-f lavfi -i color=...` packets are wrapped_avframe and
        # must be decoded into the filtergraph; the null muxer also
        # defaults to it).
        "--enable-decoder=hevc,mpeg4,theora,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,h264,vp8,vp9,av1,mpeg2video,mpeg1video,mjpeg,wmv3,vc1,wrapped_avframe"

        # Audio decoders. The mp3*/mp2* wildcards pull in the whole family
        # (mp3float is what the mp3 demuxer actually selects; mp3on4* needs
        # the mpegaudio parser). pcm_* / adpcm_* cover the "pcm/adpcm"
        # census item; the wildcards are matched by configure's case-glob
        # filter (configure:631,4743-4744), not by the shell.
        "--enable-decoder=aac,ac3,eac3,dca,truehd,mlp,mp3*,mp2*,flac,opus,vorbis,alac,wmav1,wmav2,pcm_*,adpcm_*"

        # Subtitle decoders. NOTE: 'mov_text' is the runtime name; the
        # configure component is 'movtext' (movtextdec.c:594).
        "--enable-decoder=subrip,ass,ssa,webvtt,movtext,pgssub,dvdsub"

        # Encoders. Player extension: mjpeg (thumbnail JPEGs, auto-selects
        # jpegtables+mpegvideoenc), webvtt (subtitle conversion), pcm_s16le
        # (STT `-f s16le` — the raw PCM encoder, a few KB of memcpy).
        # wrapped_avframe: the null muxer's default video codec (the
        # inventory probe `-frames:v 1 -f null -` encodes the decoded
        # frame to wrapped_avframe packets, which the muxer discards).
        "--enable-encoder=aac,libopus,rawvideo,png,mjpeg,webvtt,pcm_s16le,wrapped_avframe"

        # Parsers: demuxers only auto-select some parsers and a missing
        # parser is a SILENT degradation (demux.c falls back to
        # AVSTREAM_PARSE_NONE with a VERBOSE-level log), so list them all.
        # NOTE: the census 'avc' parser is spelled h264; the truehd parser
        # is the mlp parser. Player extension: mpegvideo (mpeg1/2 video,
        # parser_list.c:49), mjpeg, vp8, vp9, av1, vc1.
        "--enable-parser=aac,ac3,dca,mlp,mpegaudio,mpeg4video,hevc,h264,vorbis,opus,flac,mpegvideo,mjpeg,vp8,vp9,av1,vc1"

        # Bitstream filters: aac_adtstoasc is auto-selected by the mov/
        # matroska muxers but is listed explicitly for clarity; the others
        # are only reachable via an explicit -bsf and must be listed to
        # exist at all. Player extension: vp9_superframe_split is
        # auto-selected by vp9_decoder (configure:3370) — without it the
        # vp9 decoder silently degrades; vp9_superframe + av1_metadata
        # cover webm-av1 input paths.
        "--enable-bsf=aac_adtstoasc,extract_extradata,eac3_core,truehd_core,filter_units,h264_mp4toannexb,trace_headers,vp9_superframe,vp9_superframe_split,av1_metadata"

        # Filters: buffer/abuffer/buffersink/abuffersink are added to
        # filter_list.c unconditionally even under --disable-everything
        # (configure:8982-8986). The rest is the set the CLI itself inserts
        # (null/anull default graph, format/aformat negotiation, scale/
        # aresample auto-inserted conversions, trim/atrim for -t/-ss/-to,
        # and the autorotate/crop family which is default-on for rotated
        # video). Filters used by a caller-supplied -vf/-af chain must be
        # added here explicitly. Player extension: fps (thumbnail
        # `-vf fps=...`), anullsrc (silence synthesis `anullsrc=...`),
        # overlay + color (OCR lane: `-filter_complex
        # [0:N]format=rgba[subs];[1:v]format=rgba[bg];[bg][subs]overlay=...`
        # with `-f lavfi -i color=black@0:...` — the bitmap-subtitle-ocr
        # path the SW cache's v2 note has always required). overlay pulls
        # framesync.o and color shares vsrc_testsrc.o with nullsrc — both
        # via the Makefile, no extra configure components.
        "--enable-filter=null,anull,format,aformat,scale,aresample,trim,atrim,crop,transpose,hflip,vflip,rotate,fps,anullsrc,overlay,color"
    )
fi

# NOTE: the two historical `sed -i` lines that lifted librubberband out of
# ffmpeg's EXTERNAL_LIBRARY_GPL_LIST so that the rubberband filter could be
# used in the LGPL variant are REMOVED. They were the mechanism that smuggled
# GPL code into the LGPL build; the LGPL variant no longer enables
# --enable-librubberband at all.

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
