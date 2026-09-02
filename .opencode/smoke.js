// Node-side smoke test for the PTHREAD (PROXY_TO_PTHREAD) reusable ffmpeg-gpl pair.
// One module instance, MULTIPLE consecutive callMain() runs on the SAME module+memory
// (shared WebAssembly.Memory), completion detected via Module.onExit.
//
// The glue is a test-copy (worker-env + node-fs readBinary shims + a node
// worker_threads Worker shim) — NOT the delivered file. Delivered pair must run in
// a browser worker where em-pthread Workers spawn natively; here they are emulated
// with node worker_threads (SAB is shared by reference, WebAssembly.Module is
// structured-cloneable).
'use strict';
const fs = require('fs');
const { Worker: NodeWorker } = require('node:worker_threads');

const WASM_PATH = '/ffmpeg-wasm/wasm/ffmpeg-gpl.wasm';
const SAMPLE = '/ffmpeg-wasm/sample-video.mkv';
const GLUE = '/ffmpeg-wasm/wasm/ffmpeg-gpl-wv.js';

let glue = fs.readFileSync(GLUE, 'utf8');
// --- test-copy-only patches to run under plain node (worker-env build) ---
glue = glue.replace(
  'typeof process!=="undefined"&&process.versions?.node?humanReadableVersionToPacked(process.versions.node):TARGET_NOT_SUPPORTED',
  'TARGET_NOT_SUPPORTED');
glue = glue.replace('var ENVIRONMENT_IS_WORKER=!!globalThis.WorkerGlobalScope;', 'var ENVIRONMENT_IS_WORKER=true;');
glue = glue.replace('var ENVIRONMENT_IS_NODE=globalThis.process?.versions?.node&&globalThis.process?.type!="renderer";', 'var ENVIRONMENT_IS_NODE=false;');
// worker-env readBinary = sync XHR; replace with node fs so locateFile's absolute path works
glue = glue.replace(
  'readBinary=url=>{var xhr=new XMLHttpRequest;xhr.open("GET",url,false);xhr.responseType="arraybuffer";xhr.send(null);return new Uint8Array(xhr.response)}}',
  'readBinary=url=>new Uint8Array(require("node:fs").readFileSync(url))}');
for (const [needle, repl] of [
  ['var ENVIRONMENT_IS_WORKER=true;', 'forced worker flag'],
  ['var ENVIRONMENT_IS_NODE=false;', 'forced node flag'],
  ['readBinary=url=>new Uint8Array(require("node:fs").readFileSync(url))}', 'readBinary via node fs'],
  ['var currentNodeVersion=TARGET_NOT_SUPPORTED;', 'node version guard neutralized'],
]) {
  if (!glue.includes(needle)) { console.error('SMOKE HARNESS PATCH FAILED: ' + repl); process.exit(3); }
}
fs.writeFileSync('/tmp/smoke-glue.js', glue);
const createFFmpeg = require('/tmp/smoke-glue.js');

// --- node worker_threads wrapper that emulates an em-pthread worker ---
// Loads the SAME test-copy glue; globalThis.name is what the glue's
// `var isPthread=globalThis.name?.startsWith("em-pthread")` detection needs.
fs.writeFileSync('/tmp/smoke-pthread-worker.cjs', `'use strict';
const { parentPort, workerData } = require('node:worker_threads');
globalThis.name = workerData.name;          // em-pthread self-identification
globalThis.self = globalThis;
globalThis.WorkerGlobalScope = globalThis;
globalThis.location = { href: 'file://' + workerData.gluePath };
globalThis.postMessage = (msg) => parentPort.postMessage(msg);
parentPort.on('message', (msg) => { if (typeof globalThis.onmessage === 'function') globalThis.onmessage({ data: msg }); });
process.on('uncaughtException', (e) => { try { parentPort.postMessage({ __smokeWorkerError: String((e && e.stack) || e) }); } catch {} });
require(workerData.gluePath);
`);

// --- Worker shim: emscripten's `new Worker(pthreadMainJs,{name})` on main ---
const WORKER_WRAPPER = '/tmp/smoke-pthread-worker.cjs';
const SMOKE_GLUE_PATH = '/tmp/smoke-glue.js';
class WorkerShim {
  constructor(url, opts) {
    workerSpawns.push({ name: opts?.name, at: currentLabel });
    if (!opts?.name || !String(opts.name).startsWith('em-pthread')) {
      console.log(`[harness] WARNING: Worker spawned with unexpected name: ${opts?.name}`);
    }
    this._thread = new NodeWorker(WORKER_WRAPPER, {
      workerData: { gluePath: SMOKE_GLUE_PATH, name: String(opts?.name) },
      resourceLimits: { maxOldGenerationSizeMb: 2048 },
    });
    this.workerID = null;
    this.pthread_ptr = 0;
    this._thread.on('message', (msg) => {
      if (msg && msg.__smokeWorkerError) {
        console.log(`[harness][${currentLabel}] worker ${this.workerID} uncaught exception: ${msg.__smokeWorkerError}`);
        return;
      }
      this.onmessage?.({ data: msg });
    });
    this._thread.on('error', (e) => { this.onerror?.({ filename: 'worker-thread', lineno: 0, message: String(e) }); });
    this._thread.on('messageerror', (e) => { this.onerror?.({ filename: 'worker-thread', lineno: 0, message: 'messageerror: ' + String(e) }); });
  }
  postMessage(msg, transferList) {
    if (msg === 'setimmediate' || msg === '_si') return; // browser-only emulation; node has native setImmediate
    this._thread.postMessage(msg, transferList ?? []);
  }
  terminate() { return this._thread.terminate(); }
}
let workerSpawns = [];
let currentExitHandler = null;

const sampleBytes = fs.readFileSync(SAMPLE);
globalThis.self = globalThis;  // worker-env glue references `self`
globalThis.WorkerGlobalScope = globalThis;  // worker branch guard: window||WorkerGlobalScope
globalThis.location = { href: 'http://smoke.local/isl/' };  // _scriptName = self.location.href
// Emscripten resolves `new Worker(...)` on the main thread; shim BEFORE loading the glue.
globalThis.Worker = WorkerShim;

function decodeChunk(buffer, offset, length) {
  const bytes = buffer instanceof Uint8Array ? buffer.subarray(offset, offset + length)
                                            : new Uint8Array(buffer.slice(offset, offset + length));
  return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString('utf8');
}

let stderrText = '';
let stdoutText = '';
let currentLabel = 'init';
let mod = null;

const RUN_TIMEOUT_MS = 20000;

async function runFfmpeg(label, args, { expectCode } = {}) {
  currentLabel = label;
  stderrText = ''; stdoutText = '';
  const spawnsBefore = workerSpawns.length;
  const exitPromise = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`RUN TIMEOUT (${RUN_TIMEOUT_MS} ms) — onExit never fired`)), RUN_TIMEOUT_MS);
    currentExitHandler = (code) => { clearTimeout(timer); resolve(code); };
  });
  const t0 = Date.now();
  const callRet = mod.callMain(args);   // PROXY_TO_PTHREAD: returns spawn rc (0) immediately
  const spawnMs = Date.now() - t0;
  let code;
  try {
    code = await exitPromise;
  } catch (e) {
    console.log(`\n[harness] ${label}: BLOCKED — ${e.message}`);
    console.log(`[harness] ${label}: callMain returned ${callRet} in ${spawnMs} ms (spawn rc)`);
    console.log(`[harness] ${label}: stderr tail: ${JSON.stringify(stderrText.slice(-2000))}`);
    console.log(`[harness] ${label}: worker spawns during run: ${JSON.stringify(workerSpawns.slice(spawnsBefore))}`);
    console.log(`[harness] ${label}: module ABORT=${mod['ABORT']} EXITSTATUS=${mod['EXITSTATUS']} callMain callable=${typeof mod.callMain === 'function'}`);
    throw e;
  }
  const durMs = Date.now() - t0;
  const alive = typeof mod.callMain === 'function' && !mod['ABORT'];
  const noTeardown = !/worker sent an error|terminated worker|Aborted\(/.test(stderrText);
  console.log(`\n[harness] ${label}: onExit(${code}) after ${durMs} ms | callMain rc=${callRet} (spawn) | runtime alive=${alive} | no teardown messages=${noTeardown} | workers spawned during run: ${workerSpawns.length - spawnsBefore} (total ${workerSpawns.length})`);
  if (expectCode !== undefined) {
    console.log(`[harness] ${label}: expected exit code ${expectCode} -> ${code === expectCode ? 'MATCH' : 'MISMATCH'}`);
  }
  return { code, durMs, alive, noTeardown };
}

async function main() {
  console.log(`[harness] instantiating with SHARED WebAssembly.Memory({initial:2048, maximum:65536, shared:true}) ...`);
  const t0 = Date.now();
  mod = await createFFmpeg({
    locateFile: (url) => '/ffmpeg-wasm/wasm/' + url,
    wasmMemory: new WebAssembly.Memory({ initial: 2048, maximum: 65536, shared: true }),
    onExit: (code) => currentExitHandler?.(code),
    printErr: (msg) => { stderrText += msg + '\n'; },
    stderr: (buffer, offset, length) => {
      if (!length) return;
      const text = decodeChunk(buffer, offset, length);
      stderrText += text;
      process.stdout.write(`[${currentLabel}][stderr] ${text}`);
    },
    stdout: (buffer, offset, length) => {
      if (!length) return;
      const text = decodeChunk(buffer, offset, length);
      stdoutText += text;
      process.stdout.write(`[${currentLabel}][stdout] ${text}`);
    },
  });
  console.log(`[harness] instantiated in ${Date.now() - t0} ms`);

  const FS = mod.FS;
  try { FS.mkdir('/tmp'); } catch (e) { if (!/exists/i.test(String(e))) throw e; }
  FS.writeFile('/tmp/in.mkv', sampleBytes);
  console.log(`[harness] wrote /tmp/in.mkv (${sampleBytes.length} bytes) into MEMFS`);

  const results = {};

  // --- Run 1: probe (expect onExit(1): ffmpeg errors with "no output file") ---
  {
    const r = await runFfmpeg('run1-probe', ['-hide_banner', '-nostdin', '-i', '/tmp/in.mkv'], { expectCode: 1 });
    results.run1 = r;
    const bannerOk = /Stream|Duration|Audio|Video/i.test(stderrText);
    console.log(`[harness] run1: stderr contains stream banner: ${bannerOk}`);
    console.log('[harness] run1: stderr tail:', JSON.stringify(stderrText.slice(-400)));
    results.run1.bannerOk = bannerOk;
  }

  // --- Run 2: transcode (expect onExit(0), non-empty output) ---
  {
    const r = await runFfmpeg('run2-transcode', ['-loglevel', 'info', '-threads', '1', '-nostdin', '-i', '/tmp/in.mkv',
                               '-map', '0:a:0', '-c:a', 'aac', '-ac', '2', '-b:a', '160k',
                               '-f', 'adts', '/tmp/out2.aac'], { expectCode: 0 });
    let outSize = -1;
    try { outSize = FS.readFile('/tmp/out2.aac').length; } catch (e) { console.log('[harness] run2 /tmp/out2.aac missing:', String(e)); }
    console.log(`[harness] run2: /tmp/out2.aac size: ${outSize}`);
    console.log('[harness] run2: stderr tail:', JSON.stringify(stderrText.slice(-700)));
    results.run2 = { ...r, outSize };
  }

  // --- Run 3: transcode AGAIN on the same module (state reset + re-entry proof) ---
  {
    const r = await runFfmpeg('run3-transcode', ['-loglevel', 'info', '-threads', '1', '-nostdin', '-i', '/tmp/in.mkv',
                               '-map', '0:a:0', '-c:a', 'aac', '-ac', '2', '-b:a', '160k',
                               '-f', 'adts', '/tmp/out3.aac'], { expectCode: 0 });
    let outSize = -1;
    try { outSize = FS.readFile('/tmp/out3.aac').length; } catch (e) { console.log('[harness] run3 /tmp/out3.aac missing:', String(e)); }
    console.log(`[harness] run3: /tmp/out3.aac size: ${outSize}`);
    results.run3 = { ...r, outSize };
  }

  // --- Run 4: invalid args (expect onExit(non-zero), runtime still alive) ---
  {
    const r = await runFfmpeg('run4-badmap', ['-loglevel', 'info', '-threads', '1', '-nostdin', '-i', '/tmp/in.mkv',
                               '-map', '9:a:0', '-c:a', 'aac', '-ac', '2', '-b:a', '160k',
                               '-f', 'adts', '/tmp/out4.aac']);
    results.run4 = r;
    const badMapOk = /matches no streams|Stream map/i.test(stderrText);
    console.log(`[harness] run4: stderr mentions invalid stream map: ${badMapOk}`);
    console.log('[harness] run4: stderr tail:', JSON.stringify(stderrText.slice(-400)));
  }

  console.log(`\n[harness] worker spawn timeline (label -> name): ${JSON.stringify(workerSpawns)}`);
  console.log(`[harness] SMOKE RESULT:`);
  for (const [k, v] of Object.entries(results)) {
    console.log(`[harness]   ${k}: ${JSON.stringify(v)}`);
  }
  const pass =
    results.run1.code === 1 && results.run1.bannerOk &&
    results.run2.code === 0 && results.run2.outSize > 0 &&
    results.run3.code === 0 && results.run3.outSize > 0 &&
    results.run4.code !== 0 &&
    results.run1.alive && results.run2.alive && results.run3.alive && results.run4.alive &&
    results.run1.noTeardown && results.run2.noTeardown && results.run3.noTeardown && results.run4.noTeardown;
  console.log(`[harness] OVERALL: ${pass ? 'PASS' : 'FAIL'}`);
}

main().then(() => { console.log('[harness] done'); process.exit(0); }, (e) => {
  console.error('[harness] FATAL:', e && e.stack || e);
  console.error('[harness] last stderr:', JSON.stringify(stderrText.slice(-1500)));
  process.exit(1);
});
