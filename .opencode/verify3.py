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
check(not any('pthread' in n.lower() or 'mailbox' in n.lower() or 'thread' in n.lower() for m, n in funcs),
      'no pthread/thread/mailbox imports: ' + str([n for m, n in funcs if 'thread' in n.lower() or 'pthread' in n.lower()]))
check(mems and mems[0][3] == 1, 'memory import flags=1 (has max, NOT shared=3)')

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
check('__wasm_init_memory_flag' not in [nm for k, nm in exps], '___wasm_init_memory_flag absent (threadless: expected, report to player)')
check(not any(re.fullmatch(r'[A-Za-z]{1,2}', nm) for k, nm in exps if k == 0), 'no minified export names')

print('\n--- glue audits ---')
check('var entryFunction=_main;' in wv, 'callMain entryFunction = _main')
check('__emscripten_proxy_main' not in wv, 'no __emscripten_proxy_main')
check('try{runtimeKeepalivePush();var ret=entryFunction(argc,argv);return ret}catch(e){return handleException(e)}' in wv, 'patch 4 present')
check('exitJS(ret,true);return ret' not in wv, 'unpatched callMain tail absent')
check('function exitRuntime()' not in wv, 'exitRuntime() not emitted')
check('stdio streams had content in them' in wv, 'checkUnflushedContent present')
check('var runtimeKeepalivePush=' in wv and 'Module["runtimeKeepalivePush"]' in wv, 'runtimeKeepalivePush emitted+exported')
check('var runtimeKeepalivePop=' in wv and 'Module["runtimeKeepalivePop"]' in wv, 'runtimeKeepalivePop emitted+exported')
print('keepRuntimeAlive def:', re.search(r'var keepRuntimeAlive=[^;]*;', wv).group(0)[:80])
check('let i = length;try{output(buffer, offset, length)}catch(e){throw new FS.ErrnoError(29)}' in wv, 'patch 1 stdout bulk')
check('if(Module.tty && Module.tty(stream,buffer,offset,length,pos))' in wv, 'patch 2 tty hook')
check('if(input===Module.stdin){var result;try{result=input(length)}catch(e){throw new FS.ErrnoError(29)}' in wv, 'patch 3 stdin bulk')

print('\n--- pthread machinery absence in glue ---')
for needle in ('new Worker(', 'PThread', 'SharedArrayBuffer', 'Atomics.', 'importScripts', 'pthread'):
    cnt = wv.count(needle)
    check(cnt == 0, f'glue contains 0 occurrences of {needle!r}' + (f' (found {cnt})' if cnt else ''))

print('\n--- memory creation in glue ---')
i = wv.find('new WebAssembly.Memory')
print(repr(wv[max(0, i-60):i+140]))
check('shared' not in wv[i:i+200], 'default memory creation has no shared flag')

print()
for f in (WASM, WV, '/ffmpeg-wasm/wasm/ffmpeg-gpl.js'):
    h = hashlib.sha256(open(f, 'rb').read()).hexdigest()
    print(f'{os.path.basename(f)}: {os.path.getsize(f)} bytes  sha256 {h}')
print()
print('FAILURES:', fails if fails else 'NONE')
