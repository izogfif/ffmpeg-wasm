import hashlib, os, re

def uleb(b, i):
    r = 0
    s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7F) << s
        if not (x & 0x80):
            return r, i
        s += 7

def sections(data):
    i = 8
    out = {}
    while i < len(data):
        sid = data[i]
        i += 1
        size, i = uleb(data, i)
        out.setdefault(sid, []).append(i)
        i += size
    return out

def imports(path):
    data = open(path, 'rb').read()
    sec = sections(data)
    i = sec[2][0]
    n, i = uleb(data, i)
    res = []
    for _ in range(n):
        ln, i = uleb(data, i)
        mod = data[i:i + ln].decode('utf8', 'replace'); i += ln
        ln2, i = uleb(data, i)
        nm = data[i:i + ln2].decode('utf8', 'replace'); i += ln2
        kind = data[i]; i += 1
        if kind == 0: idx, i = uleb(data, i)
        elif kind == 1:
            i += 1; lim = data[i]; i += 1; mn, i = uleb(data, i)
            if lim & 1: mx, i = uleb(data, i)
        elif kind == 2:
            lim = data[i]; i += 1; mn, i = uleb(data, i)
            extra_max = None
            if lim & 1: extra_max, i = uleb(data, i)
            res.append((kind, mod, nm, lim, mn, extra_max))
            continue
        elif kind == 3: i += 2
        elif kind == 4:
            i += 2; cnt, i = uleb(data, i)
        res.append((kind, mod, nm))
    return res

WV = '/ffmpeg-wasm/wasm/ffmpeg-gpl-wv.js'
WASM = '/ffmpeg-wasm/wasm/ffmpeg-gpl.wasm'
wv = open(WV, encoding='utf-8', errors='replace').read()

fails = []
def check(cond, label):
    print(('[OK ] ' if cond else '[FAIL] ') + label)
    if not cond:
        fails.append(label)

imp = imports(WASM)
funcs = [(x[1], x[2]) for x in imp if x[0] == 0]
mems = [x for x in imp if x[0] == 2]
print('import count:', len(imp))
print('import modules:', sorted({x[1] for x in imp}))
for m in mems:
    print('memory import: module=%s name=%s flags=%d min=%d max=%s' % (m[1], m[2], m[3], m[4], m[5]))
    # flags bit 0 = has_max, bit 1 = shared. Pthreads build must be shared-compatible.
    check(m[3] & 2 != 0, 'memory import flags has shared bit set (flags=%d, shared compatible)' % m[3])
    check(m[4] == 1536, 'memory import min = 1536 pages (96mb) — player passes initial 2048 >= min')
    check(m[5] == 65536, 'memory import max = 65536 pages (4gb) — player passes maximum 65536')
    # Compatibility model vs player memory {initial:2048, maximum:65536, shared:true}:
    # flags=3 requires shared memory; min 2048 >= 1536; max 65536 == 65536.

data = open(WASM, 'rb').read()
sec = sections(data)
i = sec[7][0]
n, i = uleb(data, i)
exps = []
for _ in range(n):
    ln, i = uleb(data, i)
    nm = data[i:i + ln].decode('utf8', 'replace'); i += ln
    kind = data[i]; i += 1
    idx, i = uleb(data, i)
    exps.append((kind, nm))
check('__main_argc_argv' in [nm for k, nm in exps if k == 0], 'main exported (__main_argc_argv)')
check('__wasm_init_memory_flag' in [nm for k, nm in exps if k == 3], '__wasm_init_memory_flag exported as global (restored with pthreads)')
check(not any(re.fullmatch(r'[A-Za-z]{1,2}', nm) for k, nm in exps if k == 0), 'no minified export names')

print('\n--- glue audits ---')
check('var entryFunction=__emscripten_proxy_main;' in wv, 'callMain entryFunction = __emscripten_proxy_main (PROXY_TO_PTHREAD)')
check('try{runtimeKeepalivePush();var ret=entryFunction(argc,argv);return ret}catch(e){return handleException(e)}' in wv, 'patch 4 present (exact pinned string)')
check('exitJS(ret,true);return ret' not in wv, 'unpatched callMain tail absent')
check('function exitRuntime()' not in wv, 'exitRuntime() not emitted (EXIT_RUNTIME=0)')
check('stdio streams had content in them' in wv, 'checkUnflushedContent present')
check('var runtimeKeepalivePush=' in wv and 'Module["runtimeKeepalivePush"]' in wv, 'runtimeKeepalivePush emitted+exported')
check('var runtimeKeepalivePop=' in wv and 'Module["runtimeKeepalivePop"]' in wv, 'runtimeKeepalivePop emitted+exported')
print('keepRuntimeAlive def:', re.search(r'var keepRuntimeAlive=[^;]*;', wv).group(0)[:80])
check('let i = length;try{output(buffer, offset, length)}catch(e){throw new FS.ErrnoError(29)}' in wv, 'patch 1 stdout bulk')
check('if(Module.tty && Module.tty(stream,buffer,offset,length,pos))' in wv, 'patch 2 tty hook')
check('if(input===Module.stdin){var result;try{result=input(length)}catch(e){throw new FS.ErrnoError(29)}' in wv, 'patch 3 stdin bulk')

print('\n--- 5th patch (persistent-runtime core) ---')
P5 = 'EXITSTATUS=code;Module["onExit"]?.(code);var wvExpired=PThread.currentProxiedOperationCallerThread;if(wvExpired){PThread.currentProxiedOperationCallerThread=0;cleanupThread(wvExpired)}return'
check(P5 in wv, 'patch 5 present (exact pinned string)')
check('PThread.terminateAllThreads();Module["onExit"]' not in wv, 'unpatched teardown branch absent (terminateAllThreads before onExit)')
check('function _proc_exit(code){if(ENVIRONMENT_IS_PTHREAD)return proxyToMainThread(0,0,1,code);EXITSTATUS=code;Module["onExit"]' in wv, 'patched _proc_exit shape (proxy prefix intact, onExit fires unconditionally)')
check('ABORT=true}quit_(code,new ExitStatus(code))' not in wv, 'no ABORT+quit_ tail in _proc_exit')
check('quit_=(status,toThrow)=>{throw toThrow}' in wv, 'quit_ machinery still present (used by abort paths)')
check('var cleanupThread=pthread_ptr' in wv, 'cleanupThread present (worker pool recycling)')
check('PThread.currentProxiedOperationCallerThread' in wv, 'currentProxiedOperationCallerThread present')

print('\n--- pthread machinery presence in glue (expected for this build) ---')
for needle in ('new Worker(', 'PThread', 'SharedArrayBuffer', 'Atomics.'):
    cnt = wv.count(needle)
    check(cnt > 0, f'glue contains pthread machinery: {needle!r} x{cnt}')
# importScripts is not needed by modern pthread builds (workers reuse the main
# glue URL via new Worker(_scriptName)); 0 matches, same as the pre-reusable
# original pthread pair.
check(wv.count('importScripts') == 0, 'importScripts absent (workers reuse the main glue URL; same as original pthread build)')
check('ENVIRONMENT_IS_PTHREAD=ENVIRONMENT_IS_WORKER&&globalThis.name?.startsWith("em-pthread")' in wv, 'pthread worker self-identification via Worker name')
check('.worker.js' not in wv, 'no separate .worker.js file reference (pthreads reuse the main glue URL)')

print('\n--- memory creation in glue ---')
i = wv.find('new WebAssembly.Memory')
print(repr(wv[max(0, i-60):i+180]))
check('shared:true' in wv[i:i+220], 'default glue memory creation passes shared:true (pthreads)')

print()
for f in (WASM, WV, '/ffmpeg-wasm/wasm/ffmpeg-gpl.js'):
    h = hashlib.sha256(open(f, 'rb').read()).hexdigest()
    print(f'{os.path.basename(f)}: {os.path.getsize(f)} bytes  sha256 {h}')
print()
print('FAILURES:', fails if fails else 'NONE')
