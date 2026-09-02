# Reusable ffmpeg.wasm runtime build report

> **Addendum (2026-09-02, later): instantiation-failure diagnosis & clean rebuild** —
> see the "Addendum: `Import #0 "a"` instantiation failure" section at the bottom.

> **Addendum 3 (2026-09-02, current): proxied-main persistent design** — the
> pthread build is restored with `PROXY_TO_PTHREAD=1` + a 5th `-wv` patch that
> makes `_proc_exit` fire `onExit(code)` and return without tearing the runtime
> down. This addendum is at the bottom of the file; it supersedes the
> completion-signal semantics of the body and Addendum 2 (threadless).

Goal: one `createFFmpeg()` module instance that can run `callMain(args)` many
times, each run executing ffmpeg fully, with the runtime alive between runs and
each run's completion detectable by the caller — so the player can stop
allocating a fresh `WebAssembly.Memory` (128→334 MB) per ffmpeg run (Chrome
never reclaims dropped wasm memory; the renderer grew ~0.6 GB/min).

Built: 2026-09-02, in Docker container `ffmpeg-wasm-builder` (ubuntu:latest,
reused per README "Docker Reattach"; `docker-init.sh` toolchain already
installed inside it). Emscripten 6.0.2 (emsdk 2be309c35198053e5211e25686b136ad50b9b360),
same submodule revisions as the previous build (see `wasm/ffmpeg-gpl.txt`).

## Flags changed (`scripts/build-ffmpeg.sh`)

Only three link-time changes; everything else is byte-identical to the previous
build (same lib set, `-O3 -flto`, `MALLOC=mimalloc`, workerfs, `USE_PTHREADS=1`,
`ASSERTIONS=1`):

1. `-s EXIT_RUNTIME=1` → **`-s EXIT_RUNTIME=0`**
   Verified against emsdk sources (preamble.js:184-218): `exitRuntime()` is
   inside `#if EXIT_RUNTIME`, so with 0 it is not emitted at all — and
   `exitJS` (libcore.js:148-152) only calls `exitRuntime()` under
   `#if EXIT_RUNTIME`. Result: no `PThread.terminateRuntime()` /
   `terminateAllThreads()` on the exit path → the pthread worker pool survives
   between runs. The generated file contains no `function exitRuntime()` and
   does contain `checkUnflushedContent()` (only emitted when
   `ASSERTIONS && !EXIT_RUNTIME`), confirming the setting took effect.
2. **Dropped `-s PROXY_TO_PTHREAD=1`**
   `getEntryFunction()` (parseTools.mjs:1104-1121) now returns `_main` instead
   of `_emscripten_proxy_main`; generated code has
   `var entryFunction=_main;` and no `__emscripten_proxy_main` anywhere. main()
   runs synchronously on the calling worker thread (the player's ffmpeg
   worker), so `callMain()` becomes synchronous: it returns after main returns
   — the clean per-run completion signal. Nothing in the ffmpeg port requires
   PROXY_TO_PTHREAD (it is purely an emcc link flag; the port's configure does
   not reference it). ffmpeg's internal decode/sched threads still work via
   `USE_PTHREADS=1`.
3. `-s EXPORTED_RUNTIME_METHODS` gained **`runtimeKeepalivePush,
   runtimeKeepalivePop`**
   Guarantees the helpers are emitted (metadce would otherwise drop
   `runtimeKeepalivePush` once `PROXY_TO_PTHREAD` no longer references it) and
   exports them on the Module for the player's use.

## Patch added (`scripts/customize-ffmpeg.sh`, 4th `replace`, applied to `-wv` output only)

```bash
replace "try{var ret=entryFunction(argc,argv);exitJS(ret,true);return ret}catch(e){return handleException(e)}" \
	"try{runtimeKeepalivePush();var ret=entryFunction(argc,argv);return ret}catch(e){return handleException(e)}" \
	$OUTPUT_PATH_WV
```

This is the minimal correct patch, chosen after verifying the actual emsdk
6.0.2 runtime sources and the generated code:

- Without it, `callMain`'s tail (`exitJS(ret, true)`) runs on every normal
  return: `exitJS` → `_proc_exit(status)` → `quit_(code, new ExitStatus(code))`
  throws, unwinds through wasm into `callMain`'s catch → `handleException`
  returns `EXITSTATUS`. That works, but the *unpatched* exit path has
  destructive side effects when no keepalive is held:
  `_proc_exit` does `PThread.terminateAllThreads(); Module['onExit']?.(code);
  ABORT = true` (libwasi.js:20-38 / generated `_proc_exit`). With the
  keepalive token held, all three are skipped — runtime stays fully alive.
- The push is at the top of `try` and never popped: from the first run on,
  `keepRuntimeAlive()` (= `runtimeKeepaliveCounter > 0` in this build; there is
  no `noExitRuntime` symbol in the generated code) is true on the main runtime
  thread. ffmpeg's `main()` returns normally (fftools/ffmpeg.c `main` ends with
  cleanup + `return ret`; the only reachable C `exit()` in the player's usage
  is `sigterm_handler`'s `exit(123)` after >3 signals — signals are stubbed in
  wasm), so the normal path never even reaches `proc_exit`. The token is pure
  insurance for any `exit()` path, held for the module's lifetime. A permanent
  token is safe here: the player tears the module down by terminating its own
  worker (`kill-transcode-worker` → `worker.terminate()`), which kills the
  module, its memory, and all nested pthread workers regardless.
- Deliberately NOT done: patching `keepRuntimeAlive` to always return true.
  Worker threads share the generated code; a pthread worker's
  `invokeEntryPoint` resets its own counter to 0 per thread and relies on
  `keepRuntimeAlive()` being false after the thread body returns to call
  `__emscripten_thread_exit` and return the worker to the pool
  (libpthread.js:1140-1198). Forcing it true globally would leak every pthread
  (threads would never be cleaned up/joinable). Per-context counters keep the
  main-thread token invisible to workers — the pool keeps working normally.

## Completion-signal semantics under the new build

`callMain(args)` is **synchronous** (main runs on the calling thread):

| run outcome | what the caller sees |
|---|---|
| `main()` returns (all normal runs; `ret` from `transcode()`) | `callMain` **returns `ret`** (0 = success) |
| C code calls `exit(status)` (rare: hard-signal path) | `_proc_exit` records `EXITSTATUS = status`, throws `ExitStatus` through wasm; `callMain`'s catch → `handleException` → **returns `EXITSTATUS`** |
| wasm trap / JS exception (OOM, real crash) | `handleException` re-throws (via `quit_`); caller sees the real error. `abort()`-style failures still set `ABORT = true` — treat as module-fatal, as today |

**`Module.onExit` NEVER fires per run in this build.** It is only reached from
`_proc_exit` when `keepRuntimeAlive()` is false (generated
`_proc_exit`: `if(!keepRuntimeAlive()){PThread.terminateAllThreads();
Module["onExit"]?.(code);ABORT=true}`), and the keepalive token is held from the
first run on. The player must switch completion detection to `callMain`'s
return value. (Both paths checked: normal return bypasses the exit machinery
entirely; the `exit()` path skips onExit because the keepalive is held.)

Notes for the player migration (player repo, not changed here):

- `callMain` blocks the calling worker for the duration of the run — the worker
  event loop no longer services messages mid-run (today the em-pthread worker
  ran ffmpeg while the player's worker stayed live). FS/heap mutation races
  during the run window disappear; the stdout/stderr/tty hooks and the batch
  "Opening '<file>'" watcher now fire synchronously *inside* `callMain`.
- FS state persists across runs on one module: outputs are unlinked by the
  existing watcher code, but any per-run "fresh module = fresh FS/mount"
  assumptions (`workerfsMountedPath` reset, per-run `WebAssembly.Memory`,
  `___wasm_init_memory_flag` data-segment concerns) no longer apply — one
  memory, one FS, initialized once.
- `stderr` warning: with `ASSERTIONS=1`, any run that reaches `exit()`
  explicitly logs
  `program exited (with status: N), but keepRuntimeAlive() is set ...`
  to the error console (exitJS keeps that ASSERTIONS branch). Cosmetic only.
- Bonus: `Module.runtimeKeepalivePush` / `Module.runtimeKeepalivePop` are
  exported if the player ever wants explicit control.

## Generated-code evidence (grep of `wasm/ffmpeg-gpl-wv.js`)

Patched `callMain` (full body, generated):
```js
function callMain(args=[]){assert(runDependencies==0,'cannot call main when async dependencies remain! (listen on Module["onRuntimeInitialized"])');assert(typeof onPreRuns==="undefined"||onPreRuns.length==0,"cannot call main when preRun functions remain to be called");var entryFunction=_main;args.unshift(thisProgram);var argc=args.length;var argv=stackAlloc((argc+1)*4);var argv_ptr=argv;for(var arg of args){(growMemViews(),HEAPU32)[argv_ptr>>>2>>>0]=stringToUTF8OnStack(arg);argv_ptr+=4}(growMemViews(),HEAPU32)[argv_ptr>>>2>>>0]=0;try{runtimeKeepalivePush();var ret=entryFunction(argc,argv);return ret}catch(e){return handleException(e)}}
```
Also verified programmatically: `var entryFunction=_main` ✓; no
`__emscripten_proxy_main` ✓; no `exitJS(ret,true);return ret` ✓; no
`function exitRuntime()` ✓; `checkUnflushedContent` present ✓;
`var runtimeKeepalivePush=` / `var runtimeKeepalivePop=` emitted and
`Module["runtimeKeepalivePush"]` / `Module["runtimeKeepalivePop"]` exported ✓;
all three pre-existing `-wv` patches (stdout bulk, tty hook, stdin bulk)
present ✓; `node --check` passes on both generated JS files ✓; wasm export
table unchanged except expected deltas (`_emscripten_proxy_main` gone;
`__main_argc_argv` (main), `__wasm_init_memory_flag` intact).

## Artifacts

Built pair (build's own output layout, `wasm/`):

- `D:\intersub-4830\ffmpeg-wasm\wasm\ffmpeg-gpl-wv.js` — 173,322 bytes,
  sha256 `17c25be733f1e810a34d5a3841cc2ee7ffbadd1b02f1c77ead802bbc62e3ef98`
- `D:\intersub-4830\ffmpeg-wasm\wasm\ffmpeg-gpl.wasm` — 42,671,941 bytes,
  sha256 `d3ddf4408e9304ec873f9217f18e06a35001011176e6c9d2ee733735e437650a`
- (raw, non-`-wv` pair also produced: `wasm\ffmpeg-gpl.js` 173,031 B /
  `wasm\ffmpeg-gpl.wasm` same as above)
- emcc invocation recorded in `wasm\ffmpeg-gpl.txt` (includes
  `-s EXIT_RUNTIME=0`, no `PROXY_TO_PTHREAD`, new `EXPORTED_RUNTIME_METHODS`).

Previous artifacts backed up to `D:\intersub-4830\ffmpeg-wasm\wasm-backup-pre-reusable\`
(untracked; delete after the player validates the new pair).

## Process deviations (and why)

- Reused the existing `ffmpeg-wasm-builder` container (README "Docker
  Reattach") instead of `docker run -it` + full `docker-init.sh` — the
  container already has the toolchain installed; re-init is unnecessary.
- Did not run `release.sh` verbatim. `release.sh` starts with `rm -rf ./wasm/*`
  (would destroy the currently-working pair before a validated replacement
  exists — backed up instead) and `clean.sh` (deletes `build/` + `modules/` and
  re-clones every submodule `--remote`, which would change revisions vs the
  recorded build and re-download gigabytes). Ran `release.sh`'s GPL pass
  equivalent with the pre-built libs: `source scripts/init-emscripten.sh`,
  `FFMPEG_LGPL=false FFMPEG_SKIP_LIBS=true ./scripts/build-ffmpeg.sh &&
  ./scripts/customize-ffmpeg.sh`. The LGPL pass was skipped (player uses the
  GPL pair only); ffmpeg was already configured and compiled (2097 cached .o
  files; `make` reported "Nothing to be done"), and the changes are link-time
  only — no configure/CFLAGS delta, so the cached objects are valid.
- `scripts/build-ffmpeg.sh` also carried pre-existing uncommitted working-tree
  changes from before this session (the `-s USE_PTHREADS=1
  -s PTHREAD_POOL_SIZE_STRICT=0 -s ASSERTIONS=1` block and a typo fix) that
  match the last build's recorded invocation; they were left as-is and are
  included in this build.
- Nothing committed in either repo, per instructions.

## Validation status

Performed here: artifact structure greps, export-table diff vs old pair, JS
syntax check, `ffmpeg-gpl.txt` flag audit, emsdk-source verification of the
exit/keepalive/pthread-pool behavior. Performed NOT here: running the pair in a
browser — the player repo team validates (multi-run callMain, memory flatness,
watcher behavior under synchronous callMain).

---

## Addendum: `Import #0 "a"` instantiation failure (2026-09-02, later)

After the rebuilt pair was copied into the player (`src/vendor/ffmpeg/`), the
player's live validation failed at module creation with:

```
RuntimeError: Aborted(TypeError: WebAssembly.instantiate(): Import #0 "a": module is not an object or function)
```

### Diagnosis: the runtime instantiated the OLD (ffmpeg-wasm-new) wasm binary, not the rebuilt one

Import-section dumps (wasm import-section parser):

| binary | imports | module names | import names | memory import | export names | `__wasm_init_memory_flag` |
|---|---|---|---|---|---|---|
| ffmpeg-wasm-new (old working pair) | 94 | **all `a`** | **all minified `b..Na`** | `a.a` | **all minified `$a, Ab, ...`** | exported but minified (no such name) |
| ffmpeg-wasm pre-rebuild backup | 94 | `env`, `wasi_snapshot_preview1` | full | `env.memory` | full | exported verbatim |
| rebuilt pair (cached-object link AND clean rebuild) | 93 | `env`, `wasi_snapshot_preview1` | full | `env.memory` | full | exported verbatim |

The error names import **module** `a`; only the ffmpeg-wasm-new binary has
module `a` — as import #0 (`a.b`). The rebuilt binary's import #0 is
`env.__assert_fail`. Conclusion: category (b) — wholesale minified renames —
in the binary that was actually loaded at runtime. The shipped pair itself is
self-consistent:

- the player's vendored files were hash-identical to the rebuilt pair
  (`ffmpeg-gpl.wasm` d3ddf440..., `ffmpeg-gpl-wv.js` 17c25be7...) before the
  re-copy below;
- every one of the 93 wasm import names is present in the glue's
  `assignWasmImports` object (91 as named/shorthand keys incl. the 19
  `invoke_*` entries, plus `memory: wasmMemory`, `proc_exit`, `random_get`),
  and `getWasmImports()` exposes `{env: wasmImports, wasi_snapshot_preview1:
  wasmImports}` — exactly the two namespaces the binary imports;
- the player repo's HEAD vendored wasm (`git show
  HEAD:src/vendor/ffmpeg/ffmpeg-gpl.wasm`, sha256
  ccc4dcf6020d67ced349bd76837cd0cfb4c3a231e55c6dad98f467610ffed75d) is
  byte-identical to `D:\intersub-4830\ffmpeg-wasm-new\wasm\ffmpeg-gpl.wasm`,
  i.e. the URL `../vendor/ffmpeg/ffmpeg-gpl.wasm` (as resolved in
  `src/adapters/wasm-ffmpeg.ts`) served the old minified binary from the ISL
  service-worker cache while the new glue was in place.

So: stale-cache artifact on the player side. The player must invalidate its
service-worker cache for the vendored `.wasm` URL (cache-version bump or
explicit delete) before re-validating. Note that adding minification to this
build would NOT have made the stale binary compatible (each build's minified
`a.*` names map to different symbols), so no flag parity was added; this
repo's native convention (full names, same as the pre-rebuild backup pair)
is kept.

### Clean rebuild

To remove any staleness doubt about the reused objects, a clean ffmpeg-module
rebuild was run: all 2097 `.o` + 7 `.a` files under `modules/ffmpeg` deleted,
then `build-ffmpeg.sh` (emmake make full recompile + emcc link) +
`customize-ffmpeg.sh`. Duration: **5m34s** (-j32). External libs in `build/`
were untouched (unchanged sources/flags). Result: byte-identical artifacts to
the earlier cached-object link — same sha256s as before (`ffmpeg-gpl.wasm`
d3ddf440..., `ffmpeg-gpl-wv.js` 17c25be7..., `ffmpeg-gpl.js` b84349c1...) —
proving the previous link was already correct and deterministic.

### Re-verification of reusable-runtime semantics (all pass on the clean pair)

- `var entryFunction=_main;` (no PROXY_TO_PTHREAD; no `__emscripten_proxy_main`)
- patch 4 present: `try{runtimeKeepalivePush();var ret=entryFunction(argc,argv);return ret}catch(e){return handleException(e)}`
- no `exitJS(ret,true);return ret`; no `function exitRuntime()`;
  `checkUnflushedContent` present (EXIT_RUNTIME=0 marker)
- `runtimeKeepalivePush`/`runtimeKeepalivePop` emitted and exported on Module
- legacy -wv patches 1-3 present
- `node --check` passes on both `ffmpeg-gpl-wv.js` and `ffmpeg-gpl.js`

### `___wasm_init_memory_flag` export status (player question 5)

Still exported, **verbatim, as a global (kind=3) named
`__wasm_init_memory_flag`** in the rebuilt binary (55 exports total). It was
NOT renamed — full-name convention throughout. The player's init-once
protocol can keep addressing it by name via the glue (`Module` export), and
no rename mapping is involved.

### Final delivered hashes

- `wasm/ffmpeg-gpl.wasm` — 42,671,941 B — sha256 `d3ddf4408e9304ec873f9217f18e06a35001011176e6c9d2ee733735e437650a`
- `wasm/ffmpeg-gpl-wv.js` — 173,322 B — sha256 `17c25be733f1e810a34d5a3841cc2ee7ffbadd1b02f1c77ead802bbc62e3ef98`

(Identical to the first delivery; the clean rebuild only confirmed them.)

---

## Addendum 2: threadless rebuild (2026-09-02, after browser-validation deadlock)

Browser validation of the first rebuild deadlocked in the player's audio
transcode batch path (probe run worked; batch runs entered callMain and never
returned; the old PROXY_TO_PTHREAD=1/EXIT_RUNTIME=1 binary ran the same args
fine). Per task, the pair was rebuilt **threadless**.

### Flags diff (`scripts/build-ffmpeg.sh`, `scripts/var.sh`, `scripts/configure-ffmpeg.sh`)

- `var.sh`: removed `-pthread` from CFLAGS/LDFLAGS (at link time `-pthread`
  re-enables emscripten pthreads regardless of `USE_PTHREADS`; configure's
  own `add_allcflags -pthread` is also gone since pthreads are disabled).
- `build-ffmpeg.sh`: `-s USE_PTHREADS=1` → **`-s USE_PTHREADS=0`**; removed
  `-s PTHREAD_POOL_SIZE_STRICT=0` and `-s DEFAULT_PTHREAD_STACK_SIZE=2MB`;
  added **`-s IMPORTED_MEMORY=1`** (see below). Kept: `EXIT_RUNTIME=0`,
  `INVOKE_RUN=0`, `MODULARIZE=1` + `EXPORT_NAME=createFFmpeg`,
  `EXPORTED_RUNTIME_METHODS=[callMain, FS, HEAPU32, WORKERFS,
  runtimeKeepalivePush, runtimeKeepalivePop]`, `INITIAL_MEMORY=96mb`,
  `ALLOW_MEMORY_GROWTH=1`, `MAXIMUM_MEMORY=4gb`, `MALLOC=mimalloc`,
  `ENVIRONMENT=worker`, `STACK_SIZE=5MB`, `ASSERTIONS=1`, `USE_SDL=2`,
  `WASM_BIGINT`, workerfs.
- `EXPORTED_FUNCTIONS`: `[_main, ___wasm_init_memory_flag]` → **`[_main]`** —
  the init-once flag symbol does not exist threadless (wasm-ld:
  `symbol exported via --export not found: __wasm_init_memory_flag`); with a
  plain non-shared memory the data segments are applied once at
  instantiation, so the export is moot. **The player must stop referencing
  `Module["___wasm_init_memory_flag"]` / the shared-memory init-once
  protocol.**
- `configure-ffmpeg.sh`: added **`--disable-pthreads --disable-w32threads`**
  (configure only warns on threadless builds — verified at configure:8297;
  this also stops configure from injecting `-pthread`).
- Two ffmpeg source patches (repo sed/python-patch convention, applied by
  `configure-ffmpeg.sh`, guarded by markers):
  1. `libavutil/thread.h` — include `<pthread.h>` on threadless Emscripten
     (`__EMSCRIPTEN_PTHREAD_TYPES_FALLBACK__`): fftools uses pthread types
     unconditionally (ffmpeg.h `EncStats.lock`, ffmpeg_sched.c Scheduler),
     and thread.h only includes pthread.h under HAVE_PTHREADS. Emscripten
     ships pthread.h (types + stub declarations) in non-pthreads builds.
  2. `fftools/ffmpeg.c` `ffmpeg_cleanup()` —
     `__WASM_REUSABLE_RUNTIME_RESET__`: reset `nb_filtergraphs`,
     `nb_output_files`, `nb_input_files`, `nb_decoders`,
     `transcode_init_done`, `ffmpeg_exited` after the existing frees.
     **Required for module reuse**: the smoke test exposed that the first
     run left `nb_input_files=1`, so the second run registered its input as
     `#1` and `-map 0:a:0` failed (`Stream map '' matches no streams`,
     `Failed to set value '0:a:0' for option 'map'`). A fresh process would
     re-initialize these; a reused module must reset them. Residual risk:
     other per-run option globals (e.g. flags set by `-nostdin`,
     `-bitexact`) persist between runs unless re-passed — the player's call
     sites pass consistent option sets.

### IMPORTED_MEMORY=1 rationale

Without pthreads, emscripten defaults to DEFINING memory inside the wasm
(no `env.memory` import), which would silently ignore the player's passed-in
`wasmMemory`. With `IMPORTED_MEMORY=1` the wasm imports
`env.memory` with limits `flags=1 (has max, NOT shared) min=1536 max=65536`
— the player's `new WebAssembly.Memory({initial: 2048, maximum: 65536})`
(shared:false default) is compatible (2048 ≥ 1536). Glue default creation:
`new WebAssembly.Memory({initial:INITIAL_MEMORY/65536,maximum:65536})` — no
`shared` flag. Glue contains zero occurrences of `PThread`, `new Worker(`,
`SharedArrayBuffer`, `Atomics.`, `importScripts` (the only 2 `pthread`
substrings are removed-option assertion messages:
`Module.pthreadMainPrefixURL option was removed`).

`keepRuntimeAlive` threadless shape: `var keepRuntimeAlive=()=>true;` — the
runtime can never self-terminate; patch 4's `runtimeKeepalivePush()` call is
a formality (kept for API symmetry and future toggling).

### Node-side smoke test (emsdk node 22.16 in the build container; harness:
`.opencode/smoke.js` — test-copy glue with worker-env + node-fs readBinary
shims, NOT the delivered file; non-shared `WebAssembly.Memory({initial:2048,
maximum:65536})`; sample-video.mkv written into MEMFS as `/tmp/in.mkv`)

- **(a) probe** `-hide_banner -nostdin -i /tmp/in.mkv`:
  `callMain returned 1 in 27 ms`, stream banner on stderr ✓ — threadless
  synchronous callMain + banner parsing + non-shared memory instantiation all
  work, on the FIRST run of the persistent module.
- **(b) batch-like transcode** `-loglevel info -threads 1 -i /tmp/in.mkv -map
  0:a:0 -c:a aac -ac 2 -b:a 160k -f adts /tmp/out.aac`:
  `callMain returned -138 in 8 ms` — synchronous, **no hang**, but the run
  FAILS at the scheduler's first thread spawn:
  ```
  warning: unsupported syscall: __syscall_getrusage
  Stream mapping:
    Stream #0:1 -> #0:0 (eac3 (native) -> aac (native))
  [aost#0:0/aac @ 0x1790600] pthread_create() failed: Not supported
  Conversion failed!
  ```
  Exact block point (source-verified): `fftools/ffmpeg_sched.c`
  `task_start()` → `pthread_create()` — ffmpeg 8's CLI scheduler
  unconditionally pthread_creates every task (mux/enc/dec/demux;
  `task_init` sets `task->parent = sch` unconditionally; there is NO
  inline-scheduler fallback). With `USE_PTHREADS=0` the libc
  `pthread_create` stub fails, `sch_start` returns AVERROR(ENOSYS), ffmpeg
  exits cleanly with an error. **A threadless ffmpeg CLI cannot transcode** —
  this is the known "FFmpeg depends upon threading" issue from the repo
  README, confirmed empirically.
- Between (a) and (b) on the SAME module instance: state reset verified
  working (input correctly re-registered as `#0` in run (b)).

### What actually deadlocked the pthread build (mechanism, for the next decision)

Source-verified: `$pthreadCreateProxied__proxy: 'sync'`
(emscripten libpthread.js:762-765) — `__pthread_create_js` is annotated
`__proxy: 'sync'`: when a **pthread (task thread)** calls `pthread_create`
(e.g. a decoder task spawning avcodec frame threads), the call is proxied
SYNCHRONOUSLY to the main thread's event loop (SAB buffer + postMessage +
futex round-trip). In the no-PROXY build the main thread is the player's
worker, blocked inside the synchronous `callMain`, so it can never service
proxies: nested `pthread_create` (and FS-syscall proxying from task threads)
deadlocks. The old build worked because `PROXY_TO_PTHREAD=1` ran ffmpeg main
on an internal em-pthread worker, keeping the calling thread's event loop
free to service proxies. So: **ffmpeg's threaded scheduler cannot run
synchronously on the calling thread** — its task threads need both real
concurrency and main-thread event-loop service mid-run.

### Final delivered hashes (copied to player repo `src/vendor/ffmpeg/`)

- `ffmpeg-gpl.wasm` — 42,120,126 B — sha256 `22c497cff3fe2106ebcdef7fa02b5c049eb796106848625f7d256727f6f923c1`
- `ffmpeg-gpl-wv.js` — 147,283 B — sha256 `8c92b929636d1cacd63e311f42ebe270b9d8d236189072a87b9bf4e6e5937fa1`
- (`ffmpeg-gpl.js` raw pair: 146,992 B, sha256 `4de3e0f7bf5330b9f21684ec5d3fb86dc66a3bb159d387a40aa03f0ef5fe00d7`)
- Build time: full recompile ≈ 4 min per iteration (-j32; configure-only run ≈ 12 min).
- Deviations from the task: (1) `-sIMPORTED_MEMORY=1` added to keep the
  player's wasmMemory-passing contract working (otherwise the wasm would
  define its own memory and ignore the passed one); (2) the ffmpeg.c state
  reset patch (not requested, but required — the smoke test proved run #2
  fails without it); (3) `___wasm_init_memory_flag` dropped from
  EXPORTED_FUNCTIONS (does not exist threadless). Smoke test (b) does NOT
  succeed threadless — see the exact block point above; the threadless pair
  is deadlock-free but transcode-incapable, which the player team and
  orchestrator must weigh for the next step.

---

## Addendum 3: proxied-main persistent design (2026-09-02, current)

Browser validation settled the direction: the no-PROXY pthread build (body +
Addendum 1) deadlocks — every audio-batch run entered the synchronous
`callMain` and hung silently (one `getrusage` warning, zero stream lines).
Source-level mechanism (verified in emsdk 6.0.2 sources): ffmpeg 8's CLI
scheduler (`fftools/ffmpeg_sched.c` `task_start()`) pthread_creates its tasks;
with `USE_PTHREADS=1` every `pthread_create` from a **task thread** is proxied
SYNCHRONOUSLY to the module-hosting thread's event loop
(`$pthreadCreateProxied__proxy: 'sync'`, libpthread.js:762-765). A synchronous
`callMain` blocks that loop → the first nested spawn waits forever → deadlock.
The threadless rebuild (Addendum 2) avoided the deadlock but the scheduler
needs real threads (`pthread_create() failed: Not supported`, exit -138), so
**`PROXY_TO_PTHREAD=1` is mandatory**: ffmpeg's main runs on a dedicated
"Application main thread" em-pthread, `callMain` returns immediately after
spawning it, and the module-hosting worker's event loop stays free to service
every sync-proxied nested spawn mid-run. This is the design the ORIGINAL
(pre-reusable) pair used; the missing piece was persistence, which the 5th
patch provides.

### Flags diff (restoring pthreads on top of the reusable-runtime build)

- `scripts/var.sh`: `-pthread` restored in `CFLAGS` (configure also re-injects
  it; `-pthread` at link time enables the emscripten pthread flags).
- `scripts/build-ffmpeg.sh`:
  - restored `-s USE_PTHREADS=1`, `-s PROXY_TO_PTHREAD=1`,
    `-s PTHREAD_POOL_SIZE_STRICT=0`, `-s DEFAULT_PTHREAD_STACK_SIZE=2MB`
    (identical to the pre-reusable build);
  - kept from the reusable-runtime work: `EXIT_RUNTIME=0`, `INVOKE_RUN=0`,
    `MODULARIZE=1` + `EXPORT_NAME=createFFmpeg`, `INITIAL_MEMORY=96mb`,
    `ALLOW_MEMORY_GROWTH=1`, `MAXIMUM_MEMORY=4gb`, `MALLOC=mimalloc`,
    `ENVIRONMENT=worker`, `STACK_SIZE=5MB`, `ASSERTIONS=1`, `USE_SDL=2`,
    `WASM_BIGINT`, workerfs, and
    `EXPORTED_RUNTIME_METHODS=[callMain, FS, HEAPU32, WORKERFS,
    runtimeKeepalivePush, runtimeKeepalivePop]`;
  - kept `-s IMPORTED_MEMORY=1` (explicit; with pthreads the wasm imports
    `env.memory` anyway — see descriptor below).
- `EXPORTED_FUNCTIONS`: back to **`[_main, ___wasm_init_memory_flag]`** — the
  init-once flag symbol exists again with pthreads (shared memory / passive
  segments), exported verbatim as a global.
- `scripts/configure-ffmpeg.sh`: **removed `--disable-pthreads
  --disable-w32threads`** (the scheduler needs threads); configure reports
  `HAVE_THREADS 1` / `HAVE_PTHREADS 1`. The guarded `thread.h` fallback patch
  and the `__WASM_REUSABLE_RUNTIME_RESET__` ffmpeg.c state-reset patch are both
  kept unchanged (the first compiles out when pthreads exist; the second is
  REQUIRED — run #2 must not see run #1's registered inputs).
- Note: ffmpeg 8 can return NEGATIVE exit codes on option errors
  (`-map 9:a:0` → `onExit(-28)`, an AVERROR); callers must treat any non-zero
  code as failure, not just `1`.

### Shared-memory import descriptor (audit-verified)

`env.memory` import: `flags=3` (has_max | shared), `min=1536` (96mb), `max=65536`
(4gb). The player's `new WebAssembly.Memory({initial: 2048, maximum: 65536,
shared: true})` instantiates: shared-compatible, `2048 ≥ 1536`, max equal. Glue
default creation passes `shared: true` as well. 94 wasm imports across
`env` + `wasi_snapshot_preview1`, full (non-minified) names; export table
contains `__main_argc_argv` and the `__wasm_init_memory_flag` global.

### The 5th `-wv` patch (persistent-runtime core, `scripts/customize-ffmpeg.sh`)

Generated `_proc_exit` (pthread build) before the patch:

```js
function _proc_exit(code){if(ENVIRONMENT_IS_PTHREAD)return proxyToMainThread(0,0,1,code);EXITSTATUS=code;if(!keepRuntimeAlive()){PThread.terminateAllThreads();Module["onExit"]?.(code);ABORT=true}quit_(code,new ExitStatus(code))}
```

The patch replaces the tail (`EXITSTATUS=code;` … `quit_(…)`) — exact final
string (pin-test target):

```
EXITSTATUS=code;Module["onExit"]?.(code);var wvExpired=PThread.currentProxiedOperationCallerThread;if(wvExpired){PThread.currentProxiedOperationCallerThread=0;cleanupThread(wvExpired)}return
```

Resulting `_proc_exit` body (full, generated):

```js
function _proc_exit(code){if(ENVIRONMENT_IS_PTHREAD)return proxyToMainThread(0,0,1,code);EXITSTATUS=code;Module["onExit"]?.(code);var wvExpired=PThread.currentProxiedOperationCallerThread;if(wvExpired){PThread.currentProxiedOperationCallerThread=0;cleanupThread(wvExpired)}return}
```

Semantics:

- **Completion signal**: `Module.onExit(code)` fires with the REAL exit code
  (0 success; 1 ffmpeg error; ffmpeg 8 may also return negative AVERRORs on
  option errors) on the module-hosting worker, once per run, exactly like the
  pre-reusable build's completion path. The exit path is: ffmpeg main (on the
  Application-main-thread em-pthread) returns → `crt1_proxy_main.c`
  `_main_thread` → `exit(rtn)` → `exitJS` → pthread branch → `exitOnMainThread`
  (ASYNC-proxied to the hosting worker) → `_exit` (= `exitJS`) → `_proc_exit` →
  patched body → `onExit(code)` → return. The keepalive token pushed by
  `callMain` is popped by the generated `exitOnMainThread` before this point;
  a second token (patch 4's push) remains, so the ASSERTIONS
  `program exited (with status: N), but keepRuntimeAlive() is set (counter=N)`
  warning prints once per run on stderr — cosmetic, same category as the
  threadless build's warning.
- **The runtime NEVER tears down**: no `PThread.terminateAllThreads()`, no
  `ABORT = true`, no `quit_`/ExitStatus throw. `function exitRuntime()` is not
  even emitted (`EXIT_RUNTIME=0`); the only remaining `terminateAllThreads()`
  call site is `PThread.terminateRuntime`, which has zero callers. abort() /
  wasm-trap paths still throw/reject normally (module-drop territory, not
  exit).
- **No per-run leak (recycling clause)**: without cleanup, every run would
  leak one Worker (spawned by `_emscripten_proxy_main`'s detached
  `pthread_create`; the exited thread's `exit()` path unwinds on the pthread
  before `__emscripten_thread_exit`, so nothing returns its worker to the
  pool) plus its pthread struct with a 5 MB stack block in linear memory. The
  patch runs on the hosting worker INSIDE the async-proxied
  `exitOnMainThread`, where `PThread.currentProxiedOperationCallerThread` is
  the thread that called `exit()`; `cleanupThread()` returns its Worker to
  `PThread.unusedWorkers` and frees the thread block. The variable is zeroed
  first so the framework's own reset in
  `_emscripten_receive_on_main_thread_js` never observes a stale (freed)
  pointer. Smoke evidence: run #2 spawned 20 workers; runs #3/#4 spawned 0
  (pool fully recycled).
- **Re-entry**: `__emscripten_proxy_main` is stateless per call (fresh
  detached pthread per run; statics `_main_argc/_main_argv` are overwritten
  before the spawn), so the next `callMain` re-runs main on a pooled worker.
  Runs must still be SERIALIZED by the caller (wait for `onExit` before the
  next `callMain`): concurrent mains would race the shared statics and
  ffmpeg's process-global state.
- **Patch 4 unchanged**: its `runtimeKeepalivePush()` is redundant with the
  generated PROXY_TO_PTHREAD push in `callMain` (two tokens per run, one
  popped — the counter grows by 1 per run, harmless), but the exact string is
  kept because a vendored-pin test greps it.

### Node smoke test (`.opencode/smoke.js`, emsdk node 22.16 in the build
container; one module instance, shared `WebAssembly.Memory({initial: 2048,
maximum: 65536, shared: true})`; sample-video.mkv (40.9 MB, eac3 5.1 tracks)
written into MEMFS as `/tmp/in.mkv`; em-pthread workers emulated with node
worker_threads via a wrapper that sets `globalThis.name="em-pthread-N"` before
requiring the same test-copy glue — the glue's `var
isPthread=globalThis.name?.startsWith("em-pthread");isPthread&&createFFmpeg()`
bootstraps the worker; `WebAssembly.Module` and the SAB cross the structured
clone natively)

- **Run 1 (probe)** `-hide_banner -nostdin -i /tmp/in.mkv`:
  `onExit(1) after 81 ms`, full stream banner on stderr
  (`Stream #0:0 Video: h264 ...`, `Stream #0:1 Audio: eac3`), runtime ALIVE
  after, 1 worker spawned (the proxied main).
- **Run 2 (transcode)** `-loglevel info -threads 1 -nostdin -i /tmp/in.mkv
  -map 0:a:0 -c:a aac -ac 2 -b:a 160k -f adts /tmp/out2.aac`:
  `onExit(0) after 1788 ms`, `/tmp/out2.aac` = 1,041,522 bytes, 20 workers
  spawned (proxied main + scheduler task threads), **no hang** — the sync
  proxied nested pthread_create round-trips all completed on the free hosting
  thread. This is the exact scenario that deadlocked the no-PROXY build.
- **Run 3 (transcode again, same module)** same args → `/tmp/out3.aac`:
  `onExit(0) after 1273 ms`, output 1,041,522 bytes (byte-size identical),
  **0 workers spawned** — the pool from run 2 was fully recycled by the 5th
  patch's cleanup. ffmpeg.c state reset verified (input re-registered as #0).
- **Run 4 (invalid args)** `-map 9:a:0` variant: `onExit(-28) after 20 ms`
  (non-zero; ffmpeg 8 returns an AVERROR for option errors), stderr shows
  `Invalid input file index: 9` + `Error opening output files`, runtime still
  alive, 0 spawns (pool reused).
- Between every pair of runs: no Worker/PThread teardown messages, `callMain`
  callable again. Second harness invocation: identical outcomes (timings
  jitter only). No run hung; the 20 s watchdog never fired.
- One caveat: `Module.onExit` must be passed as a module arg (or set before
  the run's exit); the harness dispatches through a per-run handler.

### Audit battery on the final pair (`.opencode/verify4.py` — all pass)

- memory import `env.memory` flags=3 shared-compatible, min=1536, max=65536;
- glue: `var entryFunction=__emscripten_proxy_main;` (PROXY_TO_PTHREAD);
  patches 1-4 exact strings present; unpatched callMain tail absent; patch 5
  exact string present; unpatched teardown branch absent;
  `PThread.terminateAllThreads()` has no reachable call site (`exitRuntime()`
  not emitted; `terminateRuntime` uncalled); `checkUnflushedContent` present
  (EXIT_RUNTIME=0 marker); `runtimeKeepalivePush/Pop` emitted and exported;
  `quit_` machinery present (abort paths); pthread machinery present
  (`new Worker(`, `PThread` x33, `SharedArrayBuffer`, `Atomics.`);
  pthread workers self-identify via Worker name and reuse the main glue URL
  (no separate `.worker.js`; `importScripts` absent — same as the original
  pthread build);
- wasm: 94 imports (`env`, `wasi_snapshot_preview1`), full names, main +
  `__wasm_init_memory_flag` exported;
- `node --check` passes on `ffmpeg-gpl-wv.js` and `ffmpeg-gpl.js`;
- delivered pair byte-identical to the audited build pair (SHA256 equal).

### Final delivered hashes (copied to player repo `src/vendor/ffmpeg/`)

- `ffmpeg-gpl.wasm` — 42,672,287 B — sha256
  `191cd6d2e05eba55068d6d892975dbb25bc711760d802152a0976ffe2dea7d3d`
- `ffmpeg-gpl-wv.js` — 173,923 B — sha256
  `9e294493ee5c02cafd492273ff6fbd3924580de84517bb7a5fb4b918612b54a7`
- (raw non-`-wv` pair: `ffmpeg-gpl.js` 173,580 B, sha256
  `a38faffe0aae7f11f04db81b7a7d2bc0dc084b913dceeea4f4db207803a38623`;
  same `ffmpeg-gpl.wasm`)
- Build: full ffmpeg reconfigure + recompile (threadless objects invalid),
  emcc link + 5 `-wv` patches; recorded invocation in `wasm/ffmpeg-gpl.txt`.

### Notes / residual risks for the player integration

- stderr per run will contain the ASSERTIONS keepalive warning (see above) —
  cosmetic, do not parse it as an error.
- `Module.onExit` now fires once per run with the real code (this is what the
  player's run-completion watchdog already expects); `callMain`'s return value
  is the spawn rc (0) and is NOT the run's exit code.
- Calls must stay serialized (one in-flight main at a time).
- The keepalive counter grows by 1 per run (two pushes, one pop) — harmless.
- Nothing committed in either repo (per instructions).
