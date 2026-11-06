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

function streamChunk(which, bytes) {
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
      if (collector) collector('');
      return;
    }
    streamChunk(which, buffer.subarray(offset, offset + length));
  };
}

// The census contract, from the request.
const CENSUS = {
  demuxers: ['matroska', 'mov', 'avi', 'asf', 'ogg', 'aac', 'ac3', 'eac3', 'dts', 'mp3', 'flac', 'truehd'],
  // 'webm' demuxer is satisfied by the matroska demuxer's runtime name "matroska,webm"
  videoDecoders: ['hevc', 'mpeg4', 'theora', 'msmpeg4', 'msmpeg4v1', 'msmpeg4v2', 'wmv1', 'wmv2'],
  audioDecoders: ['aac', 'ac3', 'eac3', 'dca', 'truehd', 'mlp', 'mp3', 'mp3float', 'mp2', 'mp2float', 'flac', 'opus', 'vorbis', 'alac', 'wmav1', 'wmav2', 'pcm_s16le', 'pcm_s24le', 'pcm_f32le', 'pcm_mulaw', 'pcm_alaw', 'adpcm_ima_wav', 'adpcm_ms'],
  subtitleDecoders: ['subrip', 'ass', 'ssa', 'webvtt', 'mov_text', 'pgssub', 'dvdsub'],
  encoders: ['aac', 'libopus', 'rawvideo', 'png'],
  muxers: ['matroska', 'webm', 'mov', 'mp4', 'ipod', 'psp', 'ogg', 'adts', 'wav', 'image2', 'image2pipe', 'null'],
  // Must NOT be present (GPL / external codec code)
  forbiddenDecoders: ['libx264', 'libx265', 'libvpx', 'libvpx_vp9', 'libvpx_vp8', 'libopus', 'libmp3lame', 'libtheora', 'libvorbis', 'libaom_av1', 'libopenh264', 'libkvazaar', 'libsvtav1', 'libjxl'],
  forbiddenEncoders: ['libx264', 'libx265', 'libx264rgb', 'libvpx', 'libvpx_vp9', 'libvpx_vp8', 'libmp3lame', 'libtheora', 'libvorbis', 'libaom_av1', 'libopenh264', 'libkvazaar', 'libsvtav1', 'libjxl'],
  forbiddenMuxers: ['argo_asf', 'sdl2'],
};

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
  // -formats:             " DE name           description" (2-char flags).
  const names = new Set();
  for (const line of output.split('\n')) {
    const m = line.match(/^\s*([VAFS.][FXSBD.]{5})\s+([A-Za-z0-9_]+)\s/);
    if (m) { names.add(m[2]); continue; }
    const fm = line.match(/^\s*([DE.]{1,2}[E.]?)\s+([A-Za-z0-9_,]+)\s/);
    if (fm) names.add(fm[2]);
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
      ffmpeg = await createFFmpeg({
        locateFile: (f) => '../wasm/' + f,
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
      // matroska container instead (proves the PGS stream is parsed + copied).
      const r = await runFFmpeg(['-hide_banner', '-y', '-i', 'in/sample-video.mkv', '-map', '0:s', '-c:s', 'copy', 'subs.mkv']);
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
    send('error', { text: 'unknown message ' + m.type });
  } catch (err) {
    send('error', { text: String(err && err.stack || err) });
  }
};
