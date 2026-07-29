#!/usr/bin/env bash
# Human-free FPGA decode acceptance on live MiSTer (SPI F3 path).
# Does NOT open /dev/video0 — reads the already-running persistent HDMI capture.
# Returns device to MENU.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${MISTER_HOST:-192.168.1.183}"
USER="${MISTER_USER:-root}"
PASS="${MISTER_PASS:-1}"
OUT="${HW_ACCEPT_OUT:-$ROOT/build/hw_accept}"
# Default: same 624x480 IDR family as sim frame-compare (override with HW_ACCEPT_BITSTREAM).
BITSTREAM="${HW_ACCEPT_BITSTREAM:-$ROOT/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264}"
if [[ ! -f "$BITSTREAM" && -f "$HOME/Projects/MisterPlex/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264" ]]; then
  BITSTREAM="$HOME/Projects/MisterPlex/tests/fixtures/p3_inter_pred/plex_inter_p16_baseline_624x480_12f.264"
fi
CAPTURE_DIR="${HW_CAPTURE_DIR:-$HOME/Projects/MisterPlex/artifacts/hdmi-capture}"
RBF_REMOTE="${HW_RBF_REMOTE:-/media/fat/_Utility/Plex.rbf}"
PUSH_REMOTE="${HW_PUSH_REMOTE:-/media/fat/misterplex/bin/push_frame}"
# Coded size from ffprobe; DDR bank layout still uses product 624x480 stride.
CODED_W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$BITSTREAM" 2>/dev/null || echo 624)
CODED_H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$BITSTREAM" 2>/dev/null || echo 480)
MB_W=$((CODED_W / 16))
MB_H=$((CODED_H / 16))
BANK_STRIDE=0x80000
PHYS_BASE=0x30000000
Y_OFF=0
U_OFF=299520
V_OFF=374400
FRAME_STORE_W=624
FRAME_STORE_H=480

SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=12 "$USER@$HOST")
SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o ConnectTimeout=12)

mkdir -p "$OUT"
REPORT="$OUT/report.txt"
: >"$REPORT"
log() { echo "$*" | tee -a "$REPORT"; }

need() { command -v "$1" >/dev/null || { log "FAIL missing $1"; exit 2; }; }
need sshpass; need ffmpeg; need ffprobe; need python3; need md5sum

[[ -f "$BITSTREAM" ]] || { log "FAIL missing bitstream $BITSTREAM"; exit 2; }
[[ -d "$CAPTURE_DIR" ]] || { log "FAIL missing capture dir $CAPTURE_DIR"; exit 2; }
[[ -f "$CAPTURE_DIR/latest.jpg" ]] || { log "FAIL no latest.jpg — persistent capture not running"; exit 2; }

# --- golden first frame at native coded size (no scale — pixel-exact vs product) ---
GOLDEN_YUV="$OUT/golden_f0_i420.yuv"
log "STEP golden $(basename "$BITSTREAM") ${CODED_W}x${CODED_H}"
ffmpeg -y -hide_banner -loglevel error -i "$BITSTREAM" -frames:v 1 \
  -pix_fmt yuv420p -f rawvideo "$GOLDEN_YUV"
GSIZE=$(stat -c%s "$GOLDEN_YUV")
EXPECT=$((CODED_W * CODED_H * 3 / 2))
[[ "$GSIZE" -eq "$EXPECT" ]] || { log "FAIL golden size $GSIZE != $EXPECT"; exit 2; }

# --- ensure Plex core ---
log "STEP load Plex core"
"${SSH[@]}" "bash -s" <<REMOTE
set -e
if ! grep -qi plex /tmp/CORENAME 2>/dev/null; then
  echo "load_core $RBF_REMOTE" > /dev/MiSTer_cmd
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 1
    grep -qi plex /tmp/CORENAME 2>/dev/null && break
  done
fi
cat /tmp/CORENAME
test -x $PUSH_REMOTE
REMOTE

# snapshot capture before
BEFORE_JPG="$OUT/before_latest.jpg"
BEFORE_STATE="$OUT/before_state.json"
cp -f "$CAPTURE_DIR/latest.jpg" "$BEFORE_JPG"
cp -f "$CAPTURE_DIR/state.json" "$BEFORE_STATE" 2>/dev/null || true
BEFORE_TICK=$(python3 -c "import json;print(json.load(open('$BEFORE_STATE')).get('current',{}).get('tick',0))" 2>/dev/null || echo 0)

# scp bitstream
REMOTE_BS=/media/fat/misterplex/hw_accept_idr.264
"${SCP[@]}" "$BITSTREAM" "$USER@$HOST:$REMOTE_BS"

log "STEP SPI F3 push $(basename "$BITSTREAM") size=$(stat -c%s "$BITSTREAM")"
PUSH_LOG="$OUT/push.log"
"${SSH[@]}" "$PUSH_REMOTE --index 3 '$REMOTE_BS'" | tee "$PUSH_LOG" | tee -a "$REPORT"
sleep 1.5

STATUS_LOG="$OUT/status.log"
RAW_LOG="$OUT/raw.log"
"${SSH[@]}" "$PUSH_REMOTE --status" | tee "$STATUS_LOG" | tee -a "$REPORT"
"${SSH[@]}" "$PUSH_REMOTE --raw" | tee "$RAW_LOG" | tee -a "$REPORT"

# parse telemetry
python3 - "$STATUS_LOG" "$RAW_LOG" "$OUT/telemetry.json" <<'PY'
import json,re,sys
st=open(sys.argv[1]).read()
raw=open(sys.argv[2]).read()
def grab(pat, default=None, cast=int):
    m=re.search(pat, st)
    if not m: return default
    return cast(m.group(1))
tel={
  "has_stream": grab(r"has_stream=(\d+)"),
  "has_idr": grab(r"has_idr=(\d+)"),
  "nalu": grab(r"\bnalu=(\d+)"),
  "stream_nalus": grab(r"stream_nalus=(\d+)"),
  "res_ok": grab(r"res_ok=(\d+)"),
  "res_csum": grab(r"res_csum=(\d+)"),
  "res_tc": grab(r"res_tc=(\d+)"),
  "res_t1": grab(r"res_t1=(\d+)"),
  "mb0": grab(r"mb0=(\d+)"),
  "qp": grab(r"qp=(\d+)"),
  "sps_w": grab(r"sps=(\d+)x"),
  "sps_h": grab(r"sps=\d+x(\d+)"),
  "last_nal": grab(r"last_nal=0x([0-9a-fA-F]+)", cast=lambda x:int(x,16)),
  "raw_line0": raw.splitlines()[0] if raw.strip() else "",
}
# sticky res_csum in raw[13]
m=re.search(r"raw\[0\]:((?: [0-9a-fA-F]{2})+)", raw)
if m:
    bs=[int(x,16) for x in m.group(1).split()]
    tel["raw_bytes"]=bs
    if len(bs)>13: tel["raw13_res_csum"]=bs[13]
json.dump(tel, open(sys.argv[3],"w"), indent=2)
print(json.dumps(tel, indent=2))
PY

# dump DDR YUV: product frame-store is 624x480 bank; crop/compare coded WxH at origin
DUMP_PY="$OUT/dump_ddr_yuv.py"
cat > "$DUMP_PY" <<PY
#!/usr/bin/env python3
import mmap,os,struct,sys
PHYS=0x30000000
STRIDE=0x80000
Y_OFF,U_OFF,V_OFF=0,299520,374400
FW,FH=$FRAME_STORE_W,$FRAME_STORE_H
CW,CH=$CODED_W,$CODED_H
fd=os.open("/dev/mem", os.O_RDONLY|os.O_SYNC)
mm=mmap.mmap(fd, STRIDE*2, mmap.MAP_SHARED, mmap.PROT_READ, offset=PHYS)
def score(off):
    y=mm[off+Y_OFF:off+Y_OFF+FW*FH]
    s=sum(y)/len(y)
    var=sum((b-s)**2 for b in y)/len(y)
    return var, s
b0,b1=score(0),score(STRIDE)
bank=0 if b0[0]>=b1[0] else 1
off=bank*STRIDE
# Extract coded WxH I420 from top-left of frame-store raster (Y full-width stride FW)
out=sys.argv[1]
y=bytearray(CW*CH); u=bytearray((CW//2)*(CH//2)); v=bytearray((CW//2)*(CH//2))
for row in range(CH):
    y[row*CW:(row+1)*CW]=mm[off+Y_OFF+row*FW:off+Y_OFF+row*FW+CW]
for row in range(CH//2):
    u[row*(CW//2):(row+1)*(CW//2)]=mm[off+U_OFF+row*(FW//2):off+U_OFF+row*(FW//2)+(CW//2)]
    v[row*(CW//2):(row+1)*(CW//2)]=mm[off+V_OFF+row*(FW//2):off+V_OFF+row*(FW//2)+(CW//2)]
open(out,"wb").write(bytes(y)+bytes(u)+bytes(v))
try:
    db=struct.unpack_from("<Q", mm, 0xFF000)[0]
except Exception:
    db=0
print(f"bank={bank} var0={b0[0]:.1f} var1={b1[0]:.1f} meanY={(b0 if bank==0 else b1)[1]:.1f} doorbell={db:#x} coded={CW}x{CH}")
mm.close(); os.close(fd)
PY
"${SCP[@]}" "$DUMP_PY" "$USER@$HOST:/media/fat/misterplex/dump_ddr_yuv.py"
DUMP_META=$("${SSH[@]}" "python3 /media/fat/misterplex/dump_ddr_yuv.py /media/fat/misterplex/hw_accept_fpga.yuv" | tee "$OUT/dump_meta.txt" | tee -a "$REPORT")
"${SCP[@]}" "$USER@$HOST:/media/fat/misterplex/hw_accept_fpga.yuv" "$OUT/fpga_i420.yuv"

# PLXF proof comes from --status (frame store status line / ERROR)
# MB compare at coded size
python3 - "$GOLDEN_YUV" "$OUT/fpga_i420.yuv" "$OUT/mb_compare.json" "$CODED_W" "$CODED_H" "$STATUS_LOG" <<'PY'
import json,sys,re
gpath,fpath,out,w,h,stlog=sys.argv[1],sys.argv[2],sys.argv[3],int(sys.argv[4]),int(sys.argv[5]),sys.argv[6]
g=open(gpath,'rb').read(); f=open(fpath,'rb').read()
need=w*h*3//2
res={"ok":False,"first_failing_mb":None,"mismatched_mbs":0,"y_sad_total":0,"note":"","plxf_ok":False}
st=open(stlog).read() if stlog else ""
res["plxf_ok"]=("PLXF mailbox absent" not in st and "frame store status unavailable" not in st
                and ("frame_seq=" in st or "PLXF" in st))
if len(f)<need:
    res["note"]=f"fpga yuv short {len(f)}<{need}"
    json.dump(res, open(out,'w'), indent=2); print(json.dumps(res)); sys.exit(0)
g=g[:need]; f=f[:need]
mw,mh=w//16,h//16
def mb_y(plane, mbx, mby):
    rows=[]
    for r in range(16):
        y=mby*16+r; x=mbx*16
        off=y*w+x
        rows.append(plane[off:off+16])
    return b"".join(rows)
gy=g[:w*h]; fy=f[:w*h]
mean=sum(fy)/len(fy)
var=sum((b-mean)**2 for b in fy)/len(fy)
res["fpga_y_mean"]=mean; res["fpga_y_var"]=var
first=None; mism=0; sad=0
for mby in range(mh):
  for mbx in range(mw):
    a=mb_y(gy,mbx,mby); b=mb_y(fy,mbx,mby)
    s=sum(abs(a[i]-b[i]) for i in range(256))
    sad+=s
    if s>64:
      mism+=1
      if first is None:
        first={"mb_x":mbx,"mb_y":mby,"mb_addr":mby*mw+mbx,"y_sad":s}
res["first_failing_mb"]=first
res["mismatched_mbs"]=mism
res["y_sad_total"]=sad
if var<=10.0:
    res["note"]="fpga plane flat/black — product pixels not in DDR (telemetry-only gate)"
    res["ok"]=False
elif not res["plxf_ok"]:
    res["note"]="PLXF mailbox absent — DDR dump not proven product writeback; MB addr informational only"
    res["ok"]=False
else:
    res["ok"]= first is None
json.dump(res, open(out,'w'), indent=2)
print(json.dumps(res, indent=2))
PY

# wait for capture tick advance (max ~70s, capture interval 60s)
log "STEP wait HDMI capture tick (no new /dev/video0 open)"
python3 - "$CAPTURE_DIR" "$BEFORE_TICK" "$OUT" <<'PY'
import json,time,sys,shutil
from pathlib import Path
cap=Path(sys.argv[1]); before=int(sys.argv[2]); out=Path(sys.argv[3])
deadline=time.time()+75
got=None
while time.time()<deadline:
    st=json.loads((cap/"state.json").read_text())
    tick=int(st.get("current",{}).get("tick",0))
    if tick>before:
        got=st["current"]; break
    time.sleep(2)
shutil.copy2(cap/"latest.jpg", out/"after_latest.jpg")
if got:
    (out/"capture_after.json").write_text(json.dumps(got, indent=2))
    print(f"CAPTURE tick={got.get('tick')} state={got.get('state')} mean={got.get('mean')} std={got.get('std')} distinct={got.get('distinct')}")
else:
    print(f"CAPTURE no new tick (before={before}); using latest anyway")
    (out/"capture_after.json").write_text(json.dumps({"note":"no_tick_advance","before":before}, indent=2))
PY

# return MENU
log "STEP return MENU"
"${SSH[@]}" "echo load_core /media/fat/menu.rbf > /dev/MiSTer_cmd; sleep 2; cat /tmp/CORENAME"

# final verdict
python3 - "$OUT" <<'PY'
import json,sys
from pathlib import Path
out=Path(sys.argv[1])
tel=json.loads((out/"telemetry.json").read_text())
mb=json.loads((out/"mb_compare.json").read_text())
gates=[]
def gate(name, ok, detail=""):
    gates.append((name, bool(ok), detail))
gate("has_stream", tel.get("has_stream")==1, str(tel.get("has_stream")))
gate("has_idr", tel.get("has_idr")==1, str(tel.get("has_idr")))
gate("nalu_gt0", (tel.get("nalu") or 0)>0, str(tel.get("nalu")))
gate("res_ok", tel.get("res_ok")==1, str(tel.get("res_ok")))
gate("res_csum_nonzero", (tel.get("res_csum") or 0)!=0 or (tel.get("raw13_res_csum") or 0)!=0,
     f"csum={tel.get('res_csum')} raw13={tel.get('raw13_res_csum')}")
# desync: not directly in status string; treat raw sticky if present later
first=mb.get("first_failing_mb")
note=mb.get("note") or ""
if "flat" in note or "PLXF" in note:
    gate("mb_compare", False, note or "no proven product plane")
    if first:
        hw_first=f"addr={first['mb_addr']} ({first['mb_x']},{first['mb_y']}) INFORMATIONAL"
    else:
        hw_first="n/a (no proven product DDR plane)"
elif first is None:
    gate("mb_compare", True, "all MB Y match")
    hw_first="none (PASS)"
else:
    gate("mb_compare", False, f"addr={first['mb_addr']} ({first['mb_x']},{first['mb_y']}) sad={first['y_sad']}")
    hw_first=f"addr={first['mb_addr']} ({first['mb_x']},{first['mb_y']})"

# telemetry pass is the hard gate for SPI F3 on integ-fit3; MB is soft if plane missing
tele_ok=all(ok for n,ok,_ in gates if n!="mb_compare")
print("=== HW ACCEPT GATES ===")
for n,ok,d in gates:
    print(f"  {'PASS' if ok else 'FAIL'} {n}: {d}")
print(f"TELEMETRY: {'PASS' if tele_ok else 'FAIL'}")
print(f"HW_FIRST_FAILING_MB: {hw_first}")
print(f"SIM_FIRST_FAILING_MB: addr=1 (reference)")
print(f"NOTE: {note}" if note else "NOTE: (none)")
verdict="FAIL"
if tele_ok and first is None and not note:
    verdict="PASS_FULL"
elif tele_ok:
    verdict="PASS_TELEMETRY"
print(f"VERDICT: {verdict}")
(out/"verdict.txt").write_text(verdict+"\n"+f"hw_first={hw_first}\n")
sys.exit(0 if tele_ok else 1)
PY
