# Census test harness — usage & gpl restore

Browser test harness for the `FFMPEG_LGPL=true` census build
(`scripts/configure-ffmpeg.sh`, branch `lgpl-census-build`). It loads the
`-wv` module in a Web Worker, runs ffmpeg via `callMain`, and verifies the
census contract at runtime.

## Running the harness

1. Start the dev server (serves the repo root with the COOP/COEP headers
   the pthread build requires — `SharedArrayBuffer` must be available):

   ```
   set PORT=8090&& node serve.js
   ```

   Port 8080 is squatted on this machine by the `intersub-anki-sync-server`
   container and 8081 by the nginx frontend, so use 8090 (`PORT` env
   overrides `serve.js`'s default).

2. Open `http://127.0.0.1:8090/test-harness/index.html` in Chrome.
   `sample-video.mkv` is fetched and transferred to the worker on load.

3. Pick a module (dropdown) and click **Load module**, then the test buttons:

   | button | what it does |
   |---|---|
   | Runtime: -decoders / -encoders / -formats | raw ffmpeg listing |
   | Check: census contract | asserts every census demuxer/muxer/decoder/encoder is present and every GPL/external codec is absent |
   | Probe: sample-video.mkv | full input probe (9 streams) + remux to null |
   | Regression: remux matrix | mkv/mp4/mov copy, ogg (libopus), wav (aac copy), null |
   | WebM/Opus encode | audio-only webm encode via libopus |
   | PGS subtitle extract | copies the PGS stream into a matroska container |

Expected results (verified 2026-11-06, both modules): census **PASS** on the
lgpl build (126 decoders / 4 encoders / 23 formats, zero forbidden), all
functional tests **PASS** on both modules.

## Runtime contract the harness follows

- `print` is NOT in `INCOMING_MODULE_JS_API` — output arrives via the
  `stdout`/`stderr` byte hooks (`Module.stdout(buffer, offset, length)`).
- The heap is growable, so `TextDecoder` must not receive a view over the
  resizable buffer directly — copy first (`bytes.slice()`).
- With `PROXY_TO_PTHREAD`, `callMain` returns the spawn rc; the real exit
  code arrives via `Module.onExit(code)`, and stdout flushes can land
  slightly *after* `onExit` — the harness settles a run only when the
  stream has been quiet for 300 ms.
- The pthread pool spawns `mainScriptUrlOrBlob` — a worker that loads the
  glue via `importScripts` must pass it explicitly, otherwise the pool
  workers boot the host worker instead of the glue.
- `WORKERFS` mounts at `/in` (MEMFS already owns `/`), so inputs are
  referenced as `in/sample-video.mkv`.

## Restoring the old tested gpl artifacts

`wasm/` currently ships the **rebuilt** gpl pair (functionally verified in
the browser; the wasm differs from the Sept-30 tested artifact only in
LTO/parallel-link non-determinism — same size, byte-identical glue). The
original tested pair is preserved in:

```
D:\intersub-4830\ffmpeg-wasm-backup-261106-01\wasm\
```

To restore (from the repo root):

```
copy /Y D:\intersub-4830\ffmpeg-wasm-backup-261106-01\wasm\ffmpeg-gpl.wasm   wasm\
copy /Y D:\intersub-4830\ffmpeg-wasm-backup-261106-01\wasm\ffmpeg-gpl-wv.js  wasm\
copy /Y D:\intersub-4830\ffmpeg-wasm-backup-261106-01\wasm\ffmpeg-gpl.js     wasm\
copy /Y D:\intersub-4830\ffmpeg-wasm-backup-261106-01\wasm\ffmpeg-gpl.txt    wasm\
```

Verify the restored wasm hashes to the tested build:

```
certutil -hashfile wasm\ffmpeg-gpl.wasm SHA256
```

Expected (certutil prints uppercase hex without dashes):

```
D10200B794D539E86860143CC3ACAB63D8789747AF2AD15BFF92CDB72455B239
```

i.e. sha256 `d10200b794d539e86860143cc3acab63d8789747af2ad15bff92cdb72455b239`
(see `SHA256SUMS.txt` in the backup dir).

Full revert of the scripts too: `git checkout main` (the pre-change state is
also tagged `backup-261106-before-lgpl-census` at `3134a10`).
