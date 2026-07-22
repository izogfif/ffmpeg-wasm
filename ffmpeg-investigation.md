# FFmpeg WASM Investigation Notes

## Problem
`ffmpeg.callMain(['-i', 'video.mkv'])` returns exit code 6 with no output, even though the input file is loaded in the WASM FS.

## Root Cause
The Emscripten-generated `callMain` function uses `__emscripten_proxy_main` (wasm export "fb") as the entry function:

```javascript
function callMain(args = []) {
  var entryFunction = __emscripten_proxy_main;  // <-- This is the problem
  ...
  var ret = entryFunction(argc, argv);
  ...
}
```

`__emscripten_proxy_main` is a proxy/main thread wrapper that returns exit code 6 immediately without processing arguments or producing output.

## Solution
Call `_main` directly instead of `__emscripten_proxy_main`. `_main` (wasm export "ab") is the actual FFmpeg main function.

## Key Findings

### 1. Direct `_main` Calls Work
```javascript
// _main(0, 0) returns exit 0 with 1828 chars of usage info
// _main(1, 0) returns exit -28 with usage info
ffmpeg._main(0, 0)  // Works!
```

### 2. Arguments Must Be Properly Allocated
The WASM build does NOT export:
- `HEAPU8` (only `HEAPU32` is available)
- `_malloc` 
- `writeAsciiToMemory`
- `stringToUTF8`

The build DOES export:
- `___libc_malloc`
- `HEAPU32` (Uint32Array)

To write strings, we must use byte-level access via HEAPU32:

```javascript
function writeStr(ffmpeg, str, ptr) {
  for (let i = 0; i < str.length; i++) {
    const offset = ptr + i;
    const wordOffset = offset >> 2;
    const byteOffset = offset & 3;
    let word = ffmpeg.HEAPU32[wordOffset];
    word = (word & ~(0xFF << (byteOffset * 8))) | (str.charCodeAt(i) << (byteOffset * 8));
    ffmpeg.HEAPU32[wordOffset] = word;
  }
  // Null terminator
  ffmpeg.HEAPU32[(ptr + str.length) >> 2] &= ~(0xFF << ((ptr + str.length) & 3) * 8);
}
```

### 3. Working `_callMain` Implementation
```javascript
ffmpeg._callMain = function(args) {
  const prog = 'ffmpeg';
  const argc = args.length + 1;
  const argvPtr = ffmpeg.___libc_malloc((argc + 1) * 4);
  const argvBase = argvPtr >> 2;

  for (let i = 0; i < argc; i++) {
    const s = i === 0 ? prog : args[i - 1];
    const ptr = ffmpeg.___libc_malloc(s.length + 1);
    writeStr(ffmpeg, s, ptr);
    ffmpeg.HEAPU32[argvBase + i] = ptr;
  }
  ffmpeg.HEAPU32[argvBase + argc] = 0;

  return ffmpeg._main(argc, argvPtr);
};
```

Note: Use explicit array indices (`argvBase + i`) instead of incrementing offsets. Incrementing offsets (`argvOffset += 4`) causes heap corruption because `malloc` may move the heap base.

### 4. Exit Codes
- Exit code `-28` is NOT an FFmpeg error - it's an Emscripten ABORT flag
- `__emscripten_proxy_main(0, 0)` returns exit 6 (broken proxy)
- `_main(0, 0)` returns exit 0 with proper output
- `_main(4, argv)` with correct args returns exit -28 but **produces correct output**

The exit code -28 happens because Emscripten sets ABORT=true after `exitJS()` is called. This appears to be an Emscripten runtime behavior, not an FFmpeg error. The output is still correct.

### 5. Use `-hide_banner`
FFmpeg prints ~1800 chars of version/configuration info at startup. Use `-hide_banner` to suppress this and get clean output.

### 6. WASM FFmpeg Can Parse Input Files
With proper argument handling, WASM FFmpeg successfully parses input files and shows all streams:
```
Input #0, matroska,webm, from 'sample-video.mkv':
  Duration: 00:01:01.94, start: 0.000000, bitrate: 5278 kb/s
  Stream #0:0(eng): Video: h264 (High), yuv420p(tv, bt709, progressive), 1920x1080...
  Stream #0:1(rus): Audio: eac3, 48000 Hz, 5.1(side), fltp, 640 kb/s
  ... (9 streams total)
```

## Files Modified
- `index.html` - Added working `_callMain` implementation with proper string allocation
- `wasm/ffmpeg-gpl.js` - Patch at line 5853 to fix print callback (already applied)

## Environment
- WASM FFmpeg version: N-125483-g160737cf0d
- Built with Emscripten 6.0.2
- Test file: sample-video.mkv (40MB, matroska/h264)
- Chrome debugging port: 9224

## Verified Working Code
```javascript
async function loadFFmpeg() {
  ffmpeg = await createFFmpeg({
    locateFile: (file) => './wasm/' + file,
    print: (text) => { outputData += text; },
    printErr: (text) => { outputData += text; }
  });

  ffmpeg._callMain = function(args) {
    // ... implementation above ...
  };

  ffmpeg.callMain = function(args) {
    return ffmpeg._callMain(args);
  };
}

// Usage:
ffmpeg.FS.writeFile(file.name, new Uint8Array(data));
ffmpeg.callMain(['-hide_banner', '-i', file.name]);
```

## Summary
The fundamental issue was that `callMain` uses the wrong entry function. The fix is to override `callMain` to call `_main` directly with properly allocated string arguments using byte-level HEAPU32 access since HEAPU8 is not exported.