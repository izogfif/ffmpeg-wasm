#!/bin/bash
# Full verification + build pipeline for the LGPL census change.
# Runs in a FRESH container from ffmpeg-wasm-builder-base:snapshot-261106
# (the old container was deleted: its Cmd re-ran the Sept-30 pipeline).
set -eo pipefail
cd /ffmpeg-wasm
LOGD=.buildlogs
mkdir -p $LOGD
log() { echo "[$(date +%H:%M:%S)] $*"; }

log "=== 0. preflight ==="
for t in xxd python3.11 autoconf automake libtoolize pkg-config cmake; do
  command -v $t >/dev/null || { echo "MISSING TOOL: $t"; exit 1; }
done
# NOTE: Debian's libtool package ships only /usr/bin/libtoolize; the
# `libtool` wrapper itself is generated per build-tree by autoreconf.

log "=== 1. emsdk 6.0.2 install (lands in bind-mounted modules/emsdk) ==="
source scripts/init-emscripten.sh

log "=== 2. bash syntax ==="
bash -n scripts/configure-ffmpeg.sh && bash -n scripts/build-ffmpeg.sh && echo "syntax OK"

# --- stubs for the flag-equivalence tests (no real configure/link) ---
STUB=/tmp/stub; mkdir -p $STUB
printf '#!/bin/bash\nexit 0\n' > $STUB/emmake
printf '#!/bin/bash\nexit 0\n' > $STUB/emconfigure
printf '#!/bin/bash\nexit 0\n' > $STUB/emcc
chmod +x $STUB/*

# protect the wasm artifacts from the scripts' INFO_FILE writes
rm -rf /tmp/wasm-protected && cp -a wasm /tmp/wasm-protected

git show HEAD:scripts/configure-ffmpeg.sh > /tmp/old-configure.sh
git show HEAD:scripts/build-ffmpeg.sh > /tmp/old-build.sh
# the old scripts source $(dirname $0)/var.sh, so they must live next to a
# var.sh copy — run them from /tmp/oldscripts/
mkdir -p /tmp/oldscripts
cp scripts/var.sh /tmp/oldscripts/var.sh
cp /tmp/old-configure.sh /tmp/oldscripts/configure-ffmpeg.sh
cp /tmp/old-build.sh /tmp/oldscripts/build-ffmpeg.sh

log "=== 3. configure-flag equivalence (GPL variant, old vs new) ==="
PATH=$STUB:$PATH FFMPEG_LGPL=false bash /tmp/oldscripts/configure-ffmpeg.sh > /tmp/old-cfg.log 2>&1 || true
grep '^FFMPEG_CONFIG_FLAGS=' /tmp/old-cfg.log > /tmp/old-cfg-flags.txt || true
# restore the configure the old script's rubberband sed just mutated
git -C modules/ffmpeg show HEAD:configure > modules/ffmpeg/configure
chmod +x modules/ffmpeg/configure
PATH=$STUB:$PATH FFMPEG_LGPL=false bash scripts/configure-ffmpeg.sh > /tmp/new-cfg.log 2>&1 || true
grep '^FFMPEG_CONFIG_FLAGS=' /tmp/new-cfg.log > /tmp/new-cfg-flags.txt || true
if diff /tmp/old-cfg-flags.txt /tmp/new-cfg-flags.txt; then
  log "GPL CONFIGURE FLAGS: IDENTICAL"
else
  log "GPL CONFIGURE FLAGS: DIFFER -- aborting"; exit 1
fi

log "=== 4. emcc-flag equivalence (GPL variant, old vs new) ==="
PATH=$STUB:$PATH FFMPEG_LGPL=false bash /tmp/oldscripts/build-ffmpeg.sh > /tmp/old-build.log 2>&1 || true
grep '^FFMPEG_EM_FLAGS=' /tmp/old-build.log > /tmp/old-em-flags.txt || true
PATH=$STUB:$PATH FFMPEG_LGPL=false bash scripts/build-ffmpeg.sh > /tmp/new-build.log 2>&1 || true
grep '^FFMPEG_EM_FLAGS=' /tmp/new-build.log > /tmp/new-em-flags.txt || true
if diff /tmp/old-em-flags.txt /tmp/new-em-flags.txt; then
  log "GPL EMCC FLAGS: IDENTICAL"
else
  log "GPL EMCC FLAGS: DIFFER -- aborting"; exit 1
fi

# restore protected wasm artifacts
rm -rf wasm && mv /tmp/wasm-protected wasm

log "=== 5. REAL configure, LGPL variant (real emcc, no stubs) ==="
FFMPEG_LGPL=true bash scripts/configure-ffmpeg.sh > $LOGD/configure-lgpl.log 2>&1
log "configure exit: $?"
if grep -iE 'did not match|unknown' $LOGD/configure-lgpl.log; then
  log "INVALID COMPONENT NAMES PRESENT -- aborting"; exit 1
fi
log "no invalid component names"
# NOTE: this ffmpeg writes config.h + config_components.h at the SOURCE ROOT
# (not ffbuild/config.h). Component defines live in config_components.h.
H1=modules/ffmpeg/config.h
H2=modules/ffmpeg/config_components.h
check_on() { grep -qs "#define CONFIG_$1 1" $H1 $H2; }
check_off() { grep -qs "#define CONFIG_$1 0" $H1 $H2; }
MUST_ON="LIBOPUS ZLIB AVDEVICE LAVFI_INDEV MATROSKA_DEMUXER MOV_DEMUXER AVI_DEMUXER ASF_DEMUXER OGG_DEMUXER AAC_DEMUXER AC3_DEMUXER EAC3_DEMUXER DTS_DEMUXER MP3_DEMUXER FLAC_DEMUXER TRUEHD_DEMUXER WEBM_MUXER MOV_MUXER MP4_MUXER IPOD_MUXER PSP_MUXER OGG_MUXER ADTS_MUXER WAV_MUXER IMAGE2_MUXER IMAGE2PIPE_MUXER NULL_MUXER NUT_MUXER SEGMENT_MUXER ASS_MUXER WEBVTT_MUXER PCM_S16LE_MUXER HEVC_DECODER MPEG4_DECODER THEORA_DECODER MSMPEG4V1_DECODER MSMPEG4V2_DECODER MSMPEG4V3_DECODER WMV1_DECODER WMV2_DECODER H264_DECODER VP8_DECODER VP9_DECODER AV1_DECODER MPEG2VIDEO_DECODER MPEG1VIDEO_DECODER MJPEG_DECODER WMV3_DECODER VC1_DECODER WRAPPED_AVFRAME_DECODER WRAPPED_AVFRAME_ENCODER AAC_DECODER AC3_DECODER EAC3_DECODER DCA_DECODER TRUEHD_DECODER MLP_DECODER MP3_DECODER MP3FLOAT_DECODER MP2_DECODER MP2FLOAT_DECODER FLAC_DECODER OPUS_DECODER VORBIS_DECODER ALAC_DECODER WMAV1_DECODER WMAV2_DECODER PCM_S16LE_DECODER PCM_S24LE_DECODER PCM_F32LE_DECODER PCM_MULAW_DECODER PCM_ALAW_DECODER ADPCM_IMA_WAV_DECODER ADPCM_MS_DECODER SUBRIP_DECODER ASS_DECODER SSA_DECODER WEBVTT_DECODER MOVTEXT_DECODER PGSSUB_DECODER DVDSUB_DECODER AAC_ENCODER LIBOPUS_ENCODER RAWVIDEO_ENCODER PNG_ENCODER MJPEG_ENCODER WEBVTT_ENCODER PCM_S16LE_ENCODER FILE_PROTOCOL PIPE_PROTOCOL AAC_PARSER AC3_PARSER DCA_PARSER MLP_PARSER MPEGAUDIO_PARSER MPEG4VIDEO_PARSER HEVC_PARSER H264_PARSER VORBIS_PARSER OPUS_PARSER FLAC_PARSER MPEGVIDEO_PARSER MJPEG_PARSER VP8_PARSER VP9_PARSER AV1_PARSER VC1_PARSER AAC_ADTSTOASC_BSF EXTRACT_EXTRADATA_BSF EAC3_CORE_BSF TRUEHD_CORE_BSF FILTER_UNITS_BSF H264_MP4TOANNEXB_BSF VP9_SUPERFRAME_BSF VP9_SUPERFRAME_SPLIT_BSF AV1_METADATA_BSF NULL_FILTER ANULL_FILTER FORMAT_FILTER AFORMAT_FILTER SCALE_FILTER ARESAMPLE_FILTER TRIM_FILTER ATRIM_FILTER CROP_FILTER TRANSPOSE_FILTER HFLIP_FILTER VFLIP_FILTER ROTATE_FILTER FPS_FILTER ANULLSRC_FILTER OVERLAY_FILTER COLOR_FILTER"
# NOTE: AVDEVICE is ON in the player-extension census: the player's
# `-f lavfi -i anullsrc=...` needs lavfi.indev, which lives in libavdevice
# (alldevices.c registers ff_lavfi_demuxer), and build-ffmpeg.sh links
# -lavdevice for the LGPL variant accordingly. libavdevice is LGPL.
# NOTE: token names verified against this ffmpeg's headers: LIBKVAZAAR (not
# LIBKVAAZAAR), SDL2 (no SDL2_OUTDEV component exists), and libsamplerate/
# libsndfile are not configure components at all in 8.x (they were rubberband
# deps) — so they are not checkable and were dropped.
# NOTE: the NATIVE decoders (h264/vp8/vp9/av1/mpeg2/mjpeg/wmv3/vc1) are
# in-tree LGPL code and stay ON; the corresponding *external* libraries
# (libaom/libvpx/libopenh264/...) must stay OFF — that is the GPL-clean line.
MUST_OFF="LIBX264 LIBX265 LIBRUBBERBAND LIBAOM LIBVPX LIBMP3LAME LIBTHEORA LIBVORBIS LIBSVTAV1 LIBOPENH264 LIBKVAZAAR LIBJXL LIBWEBP LIBZIMG GPL SDL2 OSS_INDEV ALSA_INDEV FBDEV_INDEV V4L2_INDEV AVFOUNDATION"
FAIL=0
for c in $MUST_ON; do
  check_on $c || { echo "MISSING: $c"; FAIL=1; }
done
for c in $MUST_OFF; do
  check_off $c || { echo "NOT-OFF: $c"; FAIL=1; }
done
[ $FAIL -eq 0 ] && log "config.h: all census components ON, all forbidden OFF" || { log "config.h CHECK FAILED -- aborting"; exit 1; }

log "=== 6. build LGPL variant (SKIP_LIBS=true: build/lib already has opus+zlib) ==="
FFMPEG_LGPL=true FFMPEG_SKIP_LIBS=true bash scripts/build.sh > $LOGD/build-lgpl.log 2>&1
log "LGPL build done"

log "=== 7. build GPL variant (must be byte-identical to the tested build) ==="
FFMPEG_LGPL=false FFMPEG_SKIP_LIBS=true bash scripts/build.sh > $LOGD/build-gpl.log 2>&1
log "GPL build done"

log "=== 8. report ==="
for f in wasm/ffmpeg-lgpl.wasm wasm/ffmpeg-lgpl-wv.js wasm/ffmpeg-gpl.wasm wasm/ffmpeg-gpl-wv.js; do
  raw=$(stat -c%s "$f"); gz=$(gzip -c "$f" | wc -c)
  echo "$f raw=$raw gzip=$gz"
done
echo "--- gpl hash (must match backup d10200b7...) ---"
sha256sum wasm/ffmpeg-gpl.wasm wasm/ffmpeg-gpl-wv.js
echo "--- strings check on new lgpl wasm (lib-prefixed tokens must be 0) ---"
for tok in libx264 libx265 rubberband libvpx libmp3lame libvorbis libtheora libaom openh264 kvazaar; do
  n=$(grep -a -c -i "$tok" wasm/ffmpeg-lgpl.wasm || true)
  echo "$tok: $n"
done
echo "--- raw census tokens (native decoders legitimately carry these) ---"
# NOTE: informational only. The player extension adds the NATIVE
# h264/vp8/vp9/av1/mpeg2/mjpeg/wmv3/vc1 decoders, whose tables carry
# tokens like 'vpx' (fourcc/codec-desc strings) and 'x264' (h264 SEI
# 'x264 - core %d' formatting string). The authoritative GPL check is
# the runtime -decoders/-encoders census (test-harness) + the link list
# (EXTERNAL_LIBS above): only -lz -lopus -lavdevice are referenced.
for tok in theora vorbis aom lame vpx x264; do
  n=$(grep -a -c -i "$tok" wasm/ffmpeg-lgpl.wasm || true)
  echo "$tok: $n"
done
log "PIPELINE COMPLETE"
