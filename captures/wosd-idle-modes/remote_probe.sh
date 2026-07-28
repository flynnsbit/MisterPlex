#!/usr/bin/env bash
set -euo pipefail
CFG=/media/fat/misterplex/misterplex.conf
BAK=/media/fat/misterplex/misterplex.conf.wosd.bak
CAPDIR=/media/fat/misterplex/captures/wosd-idle-modes
mkdir -p "$CAPDIR"
rm -f "$CAPDIR"/*
restart_daemon() {
  local pids
  pids="$(pidof misterplexd 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    echo "restart_daemon: TERM $pids"
    kill $pids 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
      [ -z "$(pidof misterplexd 2>/dev/null || true)" ] && break
      sleep 0.2
    done
  fi
  cd /media/fat/misterplex
  setsid nohup ./bin/misterplexd --name MiSTerPlex --id misterplex-dev --port 3005 --conf "$CFG" >>/media/fat/misterplex/misterplexd.log 2>&1 < /dev/null &
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if wget -qO- http://127.0.0.1:3005/resources >/dev/null 2>&1; then break; fi
    sleep 0.4
  done
  echo "pids=$(pidof misterplexd | wc -w) $(pidof misterplexd)"
}
restore() {
  set +e
  echo "RESTORE: stop playback, OSD_CONTROL=0, idle bits=00"
  /media/fat/misterplex/scripts/plex_browse.sh stop >/dev/null 2>&1 || true
  if [ -f "$BAK" ]; then cp -f "$BAK" "$CFG"; rm -f "$BAK"; fi
  /media/fat/misterplex/bin/set_status --bit 14 0 --bit 15 0 >/dev/null 2>&1 || true
  restart_daemon || true
  grep -E "^OSD_CONTROL=" "$CFG" || true
}
trap restore EXIT
cp -f "$CFG" "$BAK"
echo "=== preflight ==="
echo "pid_count=$(pidof misterplexd | wc -w) pids=$(pidof misterplexd || true)"
md5sum /media/fat/misterplex/bin/misterplexd /media/fat/_Utility/Plex.rbf
find /media/fat -maxdepth 3 -name CORENAME -exec sh -c 'for f; do echo "$f=$(cat "$f")"; done' sh {} + 2>/dev/null || true
grep -E "^(OSD_CONTROL|IDLE_SCREEN|PRESENT|STREAM|PLEX_BASE)=" "$CFG" || true
/media/fat/misterplex/scripts/plex_browse.sh stop >/dev/null 2>&1 || true
/media/fat/misterplex/bin/set_status --bit 14 0 --bit 15 0 --raw
sleep 0.5
if grep -q "^OSD_CONTROL=" "$CFG"; then
  sed -i "s/^OSD_CONTROL=.*/OSD_CONTROL=1/" "$CFG"
else
  printf "\nOSD_CONTROL=1\n" >>"$CFG"
fi
restart_daemon
LOG_MARK="$(wc -c < /media/fat/misterplex/misterplexd.log 2>/dev/null || echo 0)"
sleep 2
capture() {
  local label="$1"
  echo "--- capture $label ---"
  python3 - "$CAPDIR" "$label" "$LOG_MARK" <<'PY'
import os, sys, mmap, collections, hashlib, json, time, re, struct
capdir,label,log_mark_arg=sys.argv[1:4]
BASE=0x30000000
ALIGN=0x40000
MAX_STRIDE=0x100000
MAP_LEN=MAX_STRIDE*2
MAGIC=0x504C584B
LOG='/media/fat/misterplex/misterplexd.log'
try:
    LOG_MARK=int(log_mark_arg)
except ValueError:
    LOG_MARK=0

def align_up(v, align=ALIGN):
    return (v + align - 1) & ~(align - 1)

def make_layout(coded_w, coded_h, source, display_w=None, display_h=None,
                presented_w=None, presented_h=None):
    display_w = display_w or coded_w
    display_h = display_h or coded_h
    presented_w = presented_w or display_w
    presented_h = presented_h or display_h
    frame = coded_w * coded_h * 3 // 2
    stride = align_up(frame)
    return {
        'source': source,
        'coded_width': coded_w,
        'coded_height': coded_h,
        'display_width': display_w,
        'display_height': display_h,
        'presented_width': presented_w,
        'presented_height': presented_h,
        'frame_bytes': frame,
        'bank_stride': stride,
        'doorbell_phys': BASE + stride * 2 - 0x1000,
        'y_bytes': coded_w * coded_h,
        'u_bytes': coded_w * coded_h // 4,
        'v_bytes': coded_w * coded_h // 4,
    }

def layout_for_presented(w, h, source):
    if w == 640 and h == 480:
        return make_layout(624, 480, source, display_w=618, display_h=480,
                           presented_w=640, presented_h=480)
    return make_layout(w, h, source)

def latest_logged_layout():
    try:
        with open(LOG, 'rb') as f:
            f.seek(max(0, LOG_MARK))
            text = f.read().decode('utf-8', 'replace')
    except OSError:
        return None
    matches = re.findall(r'content resolution=(\d+)x(\d+)', text)
    if not matches:
        return None
    w, h = map(int, matches[-1])
    return layout_for_presented(w, h, f'misterplexd.log content resolution={w}x{h}')

def known_layouts():
    out = [make_layout(320, 240, 'known 320x240 OSD/weak geometry'),
           layout_for_presented(640, 480, 'known 640x480 presented Plex geometry'),
           make_layout(624, 480, 'known 624x480 coded geometry')]
    logged = latest_logged_layout()
    if logged:
        out.insert(0, logged)
    return out

def scan_doorbells(mm):
    found = []
    for stride in range(ALIGN, MAX_STRIDE + 1, ALIGN):
        off = stride * 2 - 0x1000
        if off + 8 > len(mm):
            continue
        lo, hi = struct.unpack_from('<II', mm, off)
        if lo != MAGIC:
            continue
        found.append({
            'stride': stride,
            'doorbell_phys': BASE + off,
            'hi': hi,
            'bank': (hi >> 31) & 1,
            'format': (hi >> 29) & 3,
            'seq': hi & 0x1fffffff,
        })
    return found

def choose_layout(doorbells):
    layouts = known_layouts()
    live_yuv = [d for d in doorbells if d['format'] == 1]
    logged = latest_logged_layout()
    if logged and any(d['stride'] == logged['bank_stride'] for d in live_yuv):
        logged['source'] += ' + matching PLXK doorbell'
        return logged
    if logged and not live_yuv:
        logged['source'] += ' (no PLXK doorbell found)'
        return logged
    if not live_yuv:
        return None
    best = sorted(live_yuv, key=lambda d: d['seq'])[-1]
    same_stride = []
    seen = set()
    for l in layouts:
        key = (l['coded_width'], l['coded_height'], l['display_width'], l['display_height'],
               l['presented_width'], l['presented_height'])
        if l['bank_stride'] == best['stride'] and key not in seen:
            same_stride.append(l)
            seen.add(key)
    if len(same_stride) == 1:
        chosen = dict(same_stride[0])
        chosen['source'] += ' + inferred from unique PLXK stride'
        return chosen
    return None

fd=os.open('/dev/mem', os.O_RDONLY|os.O_SYNC)
mm=mmap.mmap(fd, MAP_LEN, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
doorbells=scan_doorbells(mm)
layout=choose_layout(doorbells)
stride = layout['bank_stride'] if layout else (
    sorted([d for d in doorbells if d['format'] == 1], key=lambda d: d['seq'])[-1]['stride']
    if any(d['format'] == 1 for d in doorbells) else ALIGN)
frame_len = layout['frame_bytes'] if layout else stride
banks=[]
summary={'label':label,'time':time.time(),'base':BASE,'align':ALIGN,
         'layout':layout,'doorbells':doorbells,'banks':[]}
for b in (0,1):
    start=b*stride
    data=bytes(mm[start:start+frame_len])
    banks.append(data)
    raw_path=os.path.join(capdir, f'{label}_bank{b}.yuv')
    with open(raw_path,'wb') as f: f.write(data)
    def counts(start,n,top=8):
        c=collections.Counter(data[start:start+n])
        return {'top':[[int(k),int(v)] for k,v in c.most_common(top)],
                'count_10':int(c.get(0x10,0)), 'count_2d':int(c.get(0x2d,0)),
                'count_9d':int(c.get(0x9d,0)), 'unique':int(len(c))}
    bank_summary={'bank':b,'bank_phys':BASE + b*stride,'sha256':hashlib.sha256(data).hexdigest(),
                  'bytes_captured':len(data)}
    if layout:
        Y=layout['y_bytes']; U=layout['u_bytes']; V=layout['v_bytes']
        W=layout['coded_width']; H=layout['coded_height']
        with open(os.path.join(capdir, f'{label}_bank{b}_Y.pgm'),'wb') as f:
            f.write(f'P5\n{W} {H}\n255\n'.encode('ascii')); f.write(data[:Y])
        bank_summary.update({'Y':counts(0,Y,10), 'U':counts(Y,U,8), 'V':counts(Y+U,V,8)})
    else:
        bank_summary['raw']=counts(0,len(data),10)
    summary['banks'].append(bank_summary)
summary['bank_diff_bytes']=sum(a!=b for a,b in zip(banks[0],banks[1]))
with open(os.path.join(capdir, f'{label}.json'),'w') as f: json.dump(summary,f,sort_keys=True,indent=2)
print(json.dumps(summary,sort_keys=True))
mm.close(); os.close(fd)
PY
}
block_scan() {
  local label="$1" seconds="${2:-10}" hz="${3:-5}"
  echo "--- block scan $label seconds=$seconds hz=$hz ---"
  python3 - "$CAPDIR" "$label" "$seconds" "$hz" <<'PY'
import os, sys, mmap, hashlib, json, time, struct
capdir,label,seconds_arg,hz_arg=sys.argv[1:5]
BASE=0x30000000
SPAN=0x100000
BLOCK=0x10000
ALIGN=0x40000
MAGIC=0x504C584B
seconds=float(seconds_arg)
hz=float(hz_arg)
period=1.0/hz if hz > 0 else 0.2
count=max(1, int(seconds * hz))

def scan_doorbells(mm):
    out=[]
    for stride in range(ALIGN, SPAN + 1, ALIGN):
        off = stride * 2 - 0x1000
        if off + 8 > len(mm):
            continue
        lo, hi = struct.unpack_from('<II', mm, off)
        if lo == MAGIC:
            out.append({'stride':stride,'doorbell_phys':BASE+off,'hi':hi,
                        'bank':(hi>>31)&1,'format':(hi>>29)&3,
                        'seq':hi&0x1fffffff})
    return out

fd=os.open('/dev/mem', os.O_RDONLY|os.O_SYNC)
mm=mmap.mmap(fd, SPAN, mmap.MAP_SHARED, mmap.PROT_READ, offset=BASE)
prev=None
samples=[]
for i in range(count):
    now=time.time()
    hashes=[hashlib.sha256(mm[o:o+BLOCK]).hexdigest() for o in range(0, SPAN, BLOCK)]
    changed=[] if prev is None else [n for n,(a,b) in enumerate(zip(prev, hashes)) if a != b]
    doorbells=scan_doorbells(mm)
    samples.append({'sample':i,'time':now,'changed_blocks':changed,'doorbells':doorbells})
    print('block_scan sample=%02d changed=%s doorbells=%s' % (i, changed, doorbells))
    prev=hashes
    if i != count - 1:
        time.sleep(period)
with open(os.path.join(capdir, f'{label}_block_scan.json'),'w') as f:
    json.dump({'label':label,'base':BASE,'span':SPAN,'block':BLOCK,'samples':samples},
              f,sort_keys=True,indent=2)
mm.close(); os.close(fd)
PY
}
set_mode() {
  local name="$1" b14="$2" b15="$3"
  echo "=== mode $name bits15:14=${b15}${b14} ==="
  /media/fat/misterplex/bin/set_status --bit 14 "$b14" --bit 15 "$b15" --raw | tee "$CAPDIR/${name}_set_status.txt"
  sleep 2
}
play_capture_stop() {
  local mode="$1" offset="${2:-0}"
  echo "=== play $mode offset=$offset ==="
  /media/fat/misterplex/scripts/plex_browse.sh --offset "$offset" play 3 | tee "$CAPDIR/${mode}_play.txt"
  sleep 6
  if [ "$mode" = "lastframe" ]; then
    block_scan "${mode}_play_blocks" 10 5
  fi
  capture "${mode}_play"
  if [ "$mode" = "lastframe" ]; then
    /media/fat/misterplex/scripts/plex_browse.sh pause | tee "$CAPDIR/${mode}_pause.txt"
    sleep 1
    capture "${mode}_paused_reference"
  fi
  /media/fat/misterplex/scripts/plex_browse.sh stop | tee "$CAPDIR/${mode}_stop.txt"
  sleep 3
  capture "${mode}_poststop"
}
capture baseline_logo
set_mode black 1 0
capture black_idle
play_capture_stop black 0
set_mode screensaver 0 1
capture screensaver_idle1
sleep 4
capture screensaver_idle2
play_capture_stop screensaver 30000
sleep 3
capture screensaver_poststop2
set_mode lastframe 1 1
capture lastframe_idle
play_capture_stop lastframe 60000
sleep 3
capture lastframe_poststop2
python3 - "$CAPDIR" <<'PY'
import os,json,glob,sys
capdir=sys.argv[1]
print('=== compact summaries ===')
for path in sorted(glob.glob(os.path.join(capdir,'*.json'))):
    s=json.load(open(path)); label=s['label']
    layout=s.get('layout')
    if layout:
        print(label, 'bankdiff', s['bank_diff_bytes'], 'geom',
              '%dx%d' % (layout['coded_width'], layout['coded_height']),
              'stride=0x%x' % layout['bank_stride'],
              'doorbell=0x%x' % layout['doorbell_phys'], 'source='+layout['source'])
    else:
        print(label, 'bankdiff', s['bank_diff_bytes'], 'geom=UNKNOWN',
              'doorbells='+str(s.get('doorbells', [])))
    for b in s['banks']:
        if 'Y' in b:
            yt=b['Y']; print(' bank%d phys=0x%x sha=%s Ytop=%s c10=%d c2d=%d c9d=%d Yu=%d' % (b['bank'], b['bank_phys'], b['sha256'][:12], yt['top'][:5], yt['count_10'], yt['count_2d'], yt['count_9d'], yt['unique']))
        else:
            rt=b['raw']; print(' bank%d phys=0x%x sha=%s RAWtop=%s c10=%d c2d=%d c9d=%d unique=%d' % (b['bank'], b['bank_phys'], b['sha256'][:12], rt['top'][:5], rt['count_10'], rt['count_2d'], rt['count_9d'], rt['unique']))
PY
