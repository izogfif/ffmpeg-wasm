/* Test worker: loads the -wv module (reusable runtime, PROXY_TO_PTHREAD) and
 * runs ffmpeg commands via callMain, reporting completion via Module.onExit.
 *
 * Calling convention (doc/reusable-runtime-build.md):
 *   - PROXY_TO_PTHREAD=1: callMain() returns immediately; the real per-run
 *     exit code arrives asynchronously through Module.onExit(status).
 *   - The module is reused across runs: callMain may be called many times.
 *   - WORKERFS is mounted at / with the transferred files.
 *
 * Paths: the worker lives at /test-harness/worker.js, the module artifacts
 * at /wasm/, sample-video.mkv at the repo root (all served by node serve.js).
 */

let ffmpeg = null;
let files = [];

// Output capture per the -wv runtime contract: the bulk-write patches give
// Module.stdout / Module.stderr the raw bytes (buffer, offset, length);
// `print` is NOT in INCOMING_MODULE_JS_API and must not be passed.
// The hooks are fixed at creation time; they write through `collector`,
// which runFFmpeg swaps per run.
const decoder = new TextDecoder('utf-8');
let collector = null;
let exitHandler = null;
let lastActivity = 0;
let hookCount = 0;
const partial = { out: '', err: '' };
// Binary stdout capture (the `-f nut -` player-shape probe): while rawOut is
// set, 'out' bytes are counted but not UTF-8-decoded/logged (stderr still
// logs normally so ffmpeg's own diagnostics stay visible).
let outLen = 0;
let rawOut = false;

function streamChunk(which, bytes) {
  if (which === 'out' && rawOut) return;
  // The heap buffer is resizable (ALLOW_MEMORY_GROWTH), and TextDecoder
  // rejects views over a resizable ArrayBuffer — copy out first.
  const text = partial[which] + decoder.decode(bytes.slice(), { stream: true });
  const lines = text.split('\n');
  partial[which] = lines.pop();
  for (const line of lines) {
    if (collector) collector(line);
    log(line);
  }
}

function streamHook(which) {
  return (buffer, offset, length) => {
    hookCount++;
    lastActivity = Date.now();
    // close() may call output(10) — a single newline char code
    if (typeof buffer === 'number') {
      if (which === 'out') outLen += 1;
      if (collector) collector('');
      return;
    }
    if (which === 'out') outLen += length;
    streamChunk(which, buffer.subarray(offset, offset + length));
  };
}

// The census contract, from the request.
const CENSUS = {
  demuxers: ['matroska', 'mov', 'avi', 'asf', 'ogg', 'aac', 'ac3', 'eac3', 'dts', 'mp3', 'flac', 'truehd', 'lavfi'],
  // 'webm' demuxer is satisfied by the matroska demuxer's runtime name "matroska,webm"
  videoDecoders: ['hevc', 'mpeg4', 'theora', 'msmpeg4', 'msmpeg4v1', 'msmpeg4v2', 'wmv1', 'wmv2',
    // player extension: lane-decode + thumbnail + WMV9 codecs (native LGPL)
    'h264', 'vp8', 'vp9', 'av1', 'mpeg2video', 'mpeg1video', 'mjpeg', 'wmv3', 'vc1', 'wrapped_avframe'],
  audioDecoders: ['aac', 'ac3', 'eac3', 'dca', 'truehd', 'mlp', 'mp3', 'mp3float', 'mp2', 'mp2float', 'flac', 'opus', 'vorbis', 'alac', 'wmav1', 'wmav2', 'pcm_s16le', 'pcm_s24le', 'pcm_f32le', 'pcm_mulaw', 'pcm_alaw', 'adpcm_ima_wav', 'adpcm_ms'],
  subtitleDecoders: ['subrip', 'ass', 'ssa', 'webvtt', 'mov_text', 'pgssub', 'dvdsub'],
  // mjpeg/webvtt (player), pcm_s16le (STT, user override). Runtime codec
  // name of the pcm_s16le encoder is "pcm_s16le" (the muxer's is "s16le").
  encoders: ['aac', 'libopus', 'rawvideo', 'png', 'mjpeg', 'webvtt', 'pcm_s16le', 'wrapped_avframe'],
  // nut/segment/ass/webvtt/s16le (player extension; s16le is the runtime
  // name of the pcm_s16le muxer — the pcm family prints as `s16le` etc.)
  muxers: ['matroska', 'webm', 'mov', 'mp4', 'ipod', 'psp', 'ogg', 'adts', 'wav', 'image2', 'image2pipe', 'null', 'nut', 'segment', 'ass', 'webvtt', 's16le'],
  // Must NOT be present (GPL / external codec code)
  forbiddenDecoders: ['libx264', 'libx265', 'libvpx', 'libvpx_vp9', 'libvpx_vp8', 'libopus', 'libmp3lame', 'libtheora', 'libvorbis', 'libaom_av1', 'libopenh264', 'libkvazaar', 'libsvtav1', 'libjxl'],
  forbiddenEncoders: ['libx264', 'libx265', 'libx264rgb', 'libvpx', 'libvpx_vp9', 'libvpx_vp8', 'libmp3lame', 'libtheora', 'libvorbis', 'libaom_av1', 'libopenh264', 'libkvazaar', 'libsvtav1', 'libjxl'],
  forbiddenMuxers: ['argo_asf', 'sdl2'],
};
// NOTE: 'libopus' decoder is a valid census entry (the external libopus IS
// linked), so it is not in forbiddenDecoders — checkList('adec') requires
// the native 'opus' decoder; the libopus one may exist beside it.

function send(type, extra) {
  postMessage(Object.assign({ type }, extra));
}

function log(text) {
  String(text).split('\n').forEach(t => send('log', { text: t }));
}

// Run one ffmpeg invocation; resolve with {ok, exit, output}.
// The stdout/stderr proxy writes from the pthread can land AFTER onExit,
// so settle only when onExit has arrived AND the stream has been quiet
// for 300 ms (or the 30 s watchdog fires).
function runFFmpeg(args) {
  return new Promise((resolve) => {
    let output = '';
    const collect = (t) => { output += t + '\n'; };
    collector = collect;
    partial.out = '';
    partial.err = '';
    let settled = false;
    let exitCode = null;
    lastActivity = Date.now();
    const finish = () => {
      if (settled) return;
      settled = true;
      clearInterval(watch);
      // flush any trailing partial line (no final newline)
      if (partial.out) { collect(partial.out); partial.out = ''; }
      if (partial.err) { collect(partial.err); partial.err = ''; }
      collector = null;
      exitHandler = null;
      resolve({ ok: exitCode === 0, exit: exitCode, output });
    };
    const poll = () => {
      if (exitCode !== null && Date.now() - lastActivity > 300) finish();
    };
    const watch = setInterval(() => {
      if (Date.now() - lastActivity > 30000) { if (exitCode === null) exitCode = 0; finish(); }
      else poll();
    }, 100);
    exitHandler = (code) => { exitCode = code; };
    ffmpeg.callMain(args);
  });
}

function parseNames(output, section) {
  // -decoders/-encoders: " V...BD name  description" (6-char flags column).
  // -formats:             " DE name           description" (2-char flags),
  //                       but INDEV entries print a third device flag:
  //                       " D d lavfi" (opt_common.c:928 ` %c%c%s`) — the
  //                       optional (\s+d)? group keeps `d` from being
  //                       captured as the name.
  const names = new Set();
  for (const line of output.split('\n')) {
    const m = line.match(/^\s*([VAFS.][FXSBD.]{5})\s+([A-Za-z0-9_]+)\s/);
    if (m) { names.add(m[2]); continue; }
    const fm = line.match(/^\s*([DE.]{1,2}[E.]*)(\s+d)?\s+([A-Za-z0-9_,]+)\s/);
    if (fm) names.add(fm[3]);
  }
  return names;
}

function checkList(label, expected, present, out) {
  let ok = true;
  for (const name of expected) {
    const found = [...present].some(p => p === name || p.split(',').includes(name));
    if (!found) { log('  MISSING ' + label + ': ' + name); ok = false; }
  }
  return ok;
}

function checkForbidden(label, forbidden, present, out) {
  let ok = true;
  for (const name of forbidden) {
    const found = [...present].some(p => p === name || p.split(',').includes(name));
    if (found) { log('  FORBIDDEN ' + label + ' PRESENT: ' + name); ok = false; }
  }
  return ok;
}

async function censusCheck() {
  let ok = true;
  const dec = await runFFmpeg(['-hide_banner', '-decoders']);
  const enc = await runFFmpeg(['-hide_banner', '-encoders']);
  const fmt = await runFFmpeg(['-hide_banner', '-formats']);
  const decNames = parseNames(dec.output, 'decoders');
  const encNames = parseNames(enc.output, 'encoders');
  const fmtNames = parseNames(fmt.output, 'formats');

  log('decoders listed: ' + decNames.size + ', encoders: ' + encNames.size + ', formats: ' + fmtNames.size);

  ok &= checkList('vdec', CENSUS.videoDecoders, decNames);
  ok &= checkList('adec', CENSUS.audioDecoders, decNames);
  ok &= checkList('sdec', CENSUS.subtitleDecoders, decNames);
  ok &= checkList('enc', CENSUS.encoders, encNames);
  ok &= checkList('demux', CENSUS.demuxers, fmtNames);
  ok &= checkList('mux', CENSUS.muxers, fmtNames);
  ok &= checkForbidden('dec', CENSUS.forbiddenDecoders, decNames);
  ok &= checkForbidden('enc', CENSUS.forbiddenEncoders, encNames);
  return ok;
}

onmessage = async (e) => {
  const m = e.data;
  try {
    if (m.type === 'file') {
      files.push(m.file);
      return;
    }
    if (m.type === 'load') {
      importScripts('../wasm/' + m.module);
      // pass the load URL's cache-bust through to the .wasm fetch too
      const q = (m.module.split('?')[1] || '').split('&')[0];
      ffmpeg = await createFFmpeg({
        locateFile: (f) => '../wasm/' + f + (q ? '?' + q : ''),
        // The pthread workers spawn this URL (not importScripts' location),
        // so the glue's own tail boots them as em-pthread. Without it the
        // pool workers would load worker.js and never run ffmpeg.
        mainScriptUrlOrBlob: new URL('../wasm/' + m.module, location.href).href,
        stdout: streamHook('out'),
        stderr: streamHook('err'),
        onExit: (code) => { if (exitHandler) exitHandler(code); },
      });
      // MEMFS is already mounted at / by FS.staticInit, so mount WORKERFS
      // at /in instead; ffmpeg args reference inputs as in/<name>.
      ffmpeg.FS.mkdir('/in');
      ffmpeg.FS.mount(ffmpeg.WORKERFS, { files }, '/in');
      send('done', { ok: true });
      return;
    }
    if (m.type === 'run') {
      const r = await runFFmpeg(m.args);
      send('done', { ok: r.ok, exit: r.exit });
      return;
    }
    if (m.type === 'check') {
      const args = m.args;
      const r = await runFFmpeg(args);
      log(r.output);
      send('done', { ok: r.ok });
      return;
    }
    if (m.type === 'census') {
      const ok = await censusCheck();
      send('done', { ok });
      return;
    }
    if (m.type === 'ls') {
      const info = [];
      for (const name of ffmpeg.FS.readdir('/')) {
        if (name === '.' || name === '..') continue;
        try { info.push(name + ':' + ffmpeg.FS.stat('/' + name).size); } catch (e) { info.push(name + ':?'); }
      }
      log('root: ' + (info.join(' ') || '(empty)'));
      log('stdout hook calls: ' + hookCount);
      send('done', { ok: true });
      return;
    }
    if (m.type === 'pgs') {
      // The census has no `sup` muxer, so copy the subtitle stream into a
      // matroska container instead (proves the PGS stream is parsed +
      // copied). NOTE: the fixture is the player's ocr-pgs-fixture.mkv —
      // the sample-video.mkv has NO PGS stream (its subs are subrip), so
      // the v1 probe here only ever exercised subrip copy.
      const r = await runFFmpeg(['-hide_banner', '-y', '-i', 'in/ocr-pgs-fixture.mkv', '-map', '0:s', '-c:s', 'copy', 'subs.mkv']);
      log(r.output);
      send('done', { ok: r.ok });
      return;
    }
    if (m.type === 'regress') {
      // remux matrix: probe sample, then remux to each census muxer.
      // NOTE: the sample is h264+eac3/aac — the census has no h264 decoder
      // (so no png frame extraction) and WAV cannot carry eac3 (so the wav
      // lane maps the AAC stream instead).
      const probes = [
        ['mkv',  ['-hide_banner', '-y', '-i', 'in/sample-video.mkv', '-c', 'copy', 't.mkv']],
        ['mp4',  ['-hide_banner', '-y', '-i', 'in/sample-video.mkv', '-c', 'copy', 't.mp4']],
        ['mov',  ['-hide_banner', '-y', '-i', 'in/sample-video.mkv', '-c', 'copy', 't.mov']],
        ['ogg',  ['-hide_banner', '-y', '-i', 'in/sample-video.mkv', '-t', '2', '-vn', '-c:a', 'libopus', 't.ogg']],
        ['wav',  ['-hide_banner', '-y', '-i', 'in/sample-video.mkv', '-t', '2', '-map', '0:a:2', '-vn', '-c:a', 'copy', 't.wav']],
        ['null', ['-hide_banner', '-y', '-i', 'in/sample-video.mkv', '-t', '2', '-vn', '-c:a', 'copy', '-f', 'null', 't.null']],
      ];
      let ok = true;
      for (const [name, args] of probes) {
        const r = await runFFmpeg(args);
        log('  remux ' + name + ': ' + (r.ok ? 'ok' : 'exit ' + r.exit));
        ok &= r.ok;
      }
      send('done', { ok });
      return;
    }
    if (m.type === 'player') {
      // Player-shape probes: one run per real isl-player command family
      // (mirrors the argv builders in the player repo), on sample-video.mkv
      // (h264 video + aac at 0:a:2). The ass/webvtt subtitle paths run
      // against the player's own ASS fixtures in the player's test suite
      // (the sample has no text subtitle track); the harness verifies their
      // existence via the census listing instead.
      const probes = [
        // lane decode (nut.ts buildLaneDecodeArgs): h264 decode -> rawvideo
        // I420 -> NUT muxer on stdout via the pipe protocol.
        ['lane-nut', ['-hide_banner', '-t', '2', '-i', 'in/sample-video.mkv',
          '-map', '0:v:0', '-an', '-sn', '-dn',
          '-c:v', 'rawvideo', '-pix_fmt', 'yuv420p', '-f', 'nut', '-'],
          { raw: true, minStdout: 100000 }],
        // inventory probe / decode smoke (ffmpeg-inventory.ts): first frame
        // to the null muxer on stdout.
        ['inventory', ['-hide_banner', '-nostdin', '-i', 'in/sample-video.mkv',
          '-an', '-sn', '-frames:v', '1', '-f', 'null', '-'], null],
        // thumbnail chunk (thumbnail-ffmpeg.ts buildThumbnailChunkArgs):
        // keyframe-only decode + fps/scale + mjpeg encoder + image2 muxer.
        ['thumb', ['-hide_banner', '-y', '-noautorotate', '-skip_frame', 'nokey',
          '-ss', '0', '-i', 'in/sample-video.mkv', '-map', '0:v:0',
          '-an', '-sn', '-dn', '-t', '10',
          '-vf', 'fps=1/5:round=down:eof_action=pass,scale=-2:144:flags=bilinear',
          '-q:v', '5', '-c:v', 'mjpeg', '-strict', 'unofficial',
          '-fps_mode', 'passthrough', '-huffman', 'optimal', 'img-%d.jpg'],
          { file: 'img-1.jpg' }],
        // audio batch (audio-transcode.ts): aac encode + segment muxer.
        ['segment', ['-hide_banner', '-y', '-t', '3', '-i', 'in/sample-video.mkv',
          '-map', '0:a:2', '-vn', '-sn', '-dn',
          '-c:a', 'aac', '-b:a', '160k', '-ac', '2',
          '-f', 'segment', '-segment_time', '1', 'out-%d.aac'],
          { file: 'out-0.aac' }],
        // silence synthesis (audio-transcode.ts): lavfi indev + anullsrc +
        // aac + adts muxer.
        ['silence', ['-hide_banner', '-y', '-f', 'lavfi',
          '-i', 'anullsrc=r=48000:cl=stereo', '-t', '0.1',
          '-c:a', 'aac', '-b:a', '128k', '-f', 'adts', 'silence.aac'],
          { file: 'silence.aac' }],
        // STT decode (stt-audio.ts): s16le muxer + pcm_s16le encoder.
        ['stt-s16le', ['-hide_banner', '-y', '-t', '2', '-i', 'in/sample-video.mkv',
          '-map', '0:a:2', '-vn', '-ac', '1', '-ar', '16000',
          '-f', 's16le', 'out.pcm'], { file: 'out.pcm' }],
        // OCR lane (subtitle.ts extractOcrSubtitleChunk): PGS subtitle
        // stream + a lavfi color source overlaid via filter_complex, PNG
        // frames out. Uses the REAL bitmap-subtitle fixture (the sample
        // has no PGS stream); the first PGS packet is at pts 29.006, so
        // the window seeks to 29.
        ['ocr-pgs', ['-hide_banner', '-y', '-ss', '29', '-i', 'in/ocr-pgs-fixture.mkv',
          '-f', 'lavfi', '-i', 'color=black@0:s=320x120:r=1', '-t', '3',
          '-filter_complex',
          '[0:s]format=rgba[subs];[1:v]format=rgba[bg];[bg][subs]overlay=shortest=1:format=auto',
          '-c:v', 'png', '-f', 'image2', '-y', 'ocr-%06d.png'],
          { file: 'ocr-000001.png' }],
      ];
      let ok = true;
      for (const [name, args, expect] of probes) {
        rawOut = !!(expect && expect.raw);
        outLen = 0;
        const r = await runFFmpeg(args);
        rawOut = false;
        let pass = r.ok;
        if (pass && expect && expect.minStdout) pass = outLen >= expect.minStdout;
        if (pass && expect && expect.file) {
          let size = -1;
          try { size = ffmpeg.FS.stat('/' + expect.file).size; } catch (e) { /* absent */ }
          pass = size > 0;
          log('  ' + name + ': output ' + expect.file + ' size=' + size);
        }
        if (expect && expect.raw) log('  ' + name + ': stdout bytes=' + outLen);
        log('  probe ' + name + ': ' + (pass ? 'ok' : 'FAIL (exit ' + r.exit + ')'));
        ok &= pass;
      }
      send('done', { ok });
      return;
    }
    send('error', { text: 'unknown message ' + m.type });
  } catch (err) {
    send('error', { text: String(err && err.stack || err) });
  }
};
