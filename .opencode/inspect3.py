import re

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

data = open('/ffmpeg-wasm/wasm/ffmpeg-gpl.wasm', 'rb').read()
i = 8
sec = {}
while i < len(data):
    sid = data[i]; i += 1
    size, i = uleb(data, i)
    sec.setdefault(sid, []).append(i)
    i += size
print('section ids present:', sorted(sec.keys()))
i = sec[2][0]
n, i = uleb(data, i)
print('imports:', n)
kinds = {0: 'func', 1: 'table', 2: 'mem', 3: 'glob', 4: 'tag'}
for k in range(n):
    ln, i = uleb(data, i)
    mod = data[i:i+ln].decode('utf8', 'replace'); i += ln
    ln2, i = uleb(data, i)
    nm = data[i:i+ln2].decode('utf8', 'replace'); i += ln2
    kind = data[i]; i += 1
    extra = ''
    if kind == 0:
        idx, i = uleb(data, i)
    elif kind == 1:
        i += 1; lim = data[i]; i += 1; mn, i = uleb(data, i); extra = f'flags={lim} min={mn}'
        if lim & 1:
            mx, i = uleb(data, i); extra += f' max={mx}'
    elif kind == 2:
        lim = data[i]; i += 1; mn, i = uleb(data, i); extra = f'flags={lim} min={mn}'
        if lim & 1:
            mx, i = uleb(data, i); extra += f' max={mx}'
    elif kind == 3:
        i += 2
    elif kind == 4:
        i += 2; cnt, i = uleb(data, i)
    print(f'  [{k+1}] {kinds.get(kind, kind):5} {mod}.{nm} {extra}')

wv = open('/ffmpeg-wasm/wasm/ffmpeg-gpl-wv.js', encoding='utf-8', errors='replace').read()
print('\npthread occurrences in glue:')
for m in re.finditer(r'pthread', wv):
    print('  @', m.start(), ':', repr(wv[m.start()-120:m.start()+120]))
