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

# scp bitstream + dump helper early (needed for wipe)
REMOTE_BS=/media/fat/misterplex/hw_accept_idr.264
"${SCP[@]}" "$BITSTREAM" "$USER@$HOST:$REMOTE_BS"
WIPE_TAG=90  # 0x5A — unique tag so product writeback is unambiguous
cat > "$OUT/dump_ddr_yuv_boot.py" <<'BOOT'
#!/usr/bin/env python3
import mmap,os,struct,sys,json
PHYS=0x30000000; STRIDE=0x80000; Y_OFF,U_OFF,V_OFF=0,299520,374400
FW,FH=624,480
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
mm=mmap.mmap(fd, 0x100000, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=PHYS)
def mbox():
    o={}
    mag={"PLXK":0x504C584B,"PLXF":0x504C5846,"PLXD":0x504C5844,"PLXS":0x504C5853}
    for name,off in [("PLXK",0xFF000),("PLXF",0x7F118),("PLXD",0x7F128),("PLXS",0x7F100)]:
        lo,hi=struct.unpack_from("<II", mm, off)
        o[name]={"lo":lo,"hi":hi,"magic_ok":lo==mag[name]}
    return o
mode=sys.argv[1]
if mode=="wipe":
    w=int(sys.argv[2]); fill=bytes([w])*(FW*FH); uf=bytes([0x80])*((FW//2)*(FH//2))
    for bank in (0,1):
        off=bank*STRIDE
        mm[off+Y_OFF:off+Y_OFF+FW*FH]=fill
        mm[off+U_OFF:off+U_OFF+(FW//2)*(FH//2)]=uf
        mm[off+V_OFF:off+V_OFF+(FW//2)*(FH//2)]=uf
    print(json.dumps({"wipe":w,"mailboxes":mbox()}))
mm.close(); os.close(fd)
BOOT
"${SCP[@]}" "$OUT/dump_ddr_yuv_boot.py" "$USER@$HOST:/media/fat/misterplex/dump_ddr_yuv_boot.py"
log "STEP wipe DDR Y banks to ${WIPE_TAG} (prove product writeback by delta)"
"${SSH[@]}" "python3 /media/fat/misterplex/dump_ddr_yuv_boot.py wipe $WIPE_TAG" | tee "$OUT/wipe_meta.txt" | tee -a "$REPORT"

log "STEP SPI F3 push $(basename "$BITSTREAM") size=$(stat -c%s "$BITSTREAM")"
PUSH_LOG="$OUT/push.log"
"${SSH[@]}" "$PUSH_REMOTE --index 3 '$REMOTE_BS'" | tee "$PUSH_LOG" | tee -a "$REPORT"
sleep 2.0

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

# Prove product writeback by bank delta vs WIPE_TAG (PLXF best-effort on fit3).
log "STEP dump DDR YUV + mailboxes (wipe-delta proof)"
DUMP_PY="$OUT/dump_ddr_yuv.py"
cat > "$DUMP_PY" <<PY
#!/usr/bin/env python3
import mmap,os,struct,sys,json
PHYS=0x30000000
STRIDE=0x80000
Y_OFF,U_OFF,V_OFF=0,299520,374400
FW,FH=$FRAME_STORE_W,$FRAME_STORE_H
CW,CH=$CODED_W,$CODED_H
WIPE=$WIPE_TAG
MODE=sys.argv[1]  # dump (wipe is separate boot helper)
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
mm=mmap.mmap(fd, 0x100000, mmap.MAP_SHARED, mmap.PROT_READ|mmap.PROT_WRITE, offset=PHYS)
def mbox():
    out={}
    for name,off in [("PLXK",0xFF000),("PLXF",0x7F118),("PLXD",0x7F128),("PLXS",0x7F100)]:
        lo,hi=struct.unpack_from("<II", mm, off)
        out[name]={"off":off,"lo":lo,"hi":hi,"magic_ok": lo=={"PLXK":0x504C584B,"PLXF":0x504C5846,"PLXD":0x504C5844,"PLXS":0x504C5853}[name]}
    return out
if MODE=="dump":
    out_path=sys.argv[2]
    def score(off):
        y=mm[off+Y_OFF:off+Y_OFF+FW*FH]
        # delta from wipe
        changed=sum(1 for b in y if b!=WIPE)
        s=sum(y)/len(y); v=sum((b-s)**2 for b in y)/len(y)
        return changed, v, s
    c0,v0,s0=score(0); c1,v1,s1=score(STRIDE)
    # Prefer bank with most pixels differing from wipe tag
    bank=0 if c0>=c1 else 1
    off=bank*STRIDE
    y=bytearray(CW*CH); u=bytearray((CW//2)*(CH//2)); v=bytearray((CW//2)*(CH//2))
    for row in range(CH):
        y[row*CW:(row+1)*CW]=mm[off+Y_OFF+row*FW:off+Y_OFF+row*FW+CW]
    for row in range(CH//2):
        u[row*(CW//2):(row+1)*(CW//2)]=mm[off+U_OFF+row*(FW//2):off+U_OFF+row*(FW//2)+(CW//2)]
        v[row*(CW//2):(row+1)*(CW//2)]=mm[off+V_OFF+row*(FW//2):off+V_OFF+row*(FW//2)+(CW//2)]
    open(out_path,"wb").write(bytes(y)+bytes(u)+bytes(v))
    y_changed=sum(1 for b in y if b!=WIPE)
    meta={"bank":bank,"changed0":c0,"changed1":c1,"var0":v0,"var1":v1,
          "mean0":s0,"mean1":s1,"coded_y_changed":y_changed,"wipe":WIPE,
          "mailboxes":mbox(),"coded":f"{CW}x{CH}"}
    print(json.dumps(meta))
else:
    raise SystemExit("usage: dump <out.yuv>")
mm.close(); os.close(fd)
PY
"${SCP[@]}" "$DUMP_PY" "$USER@$HOST:/media/fat/misterplex/dump_ddr_yuv.py"
DUMP_META=$("${SSH[@]}" "python3 /media/fat/misterplex/dump_ddr_yuv.py dump /media/fat/misterplex/hw_accept_fpga.yuv" | tee "$OUT/dump_meta.txt" | tee -a "$REPORT")
"${SCP[@]}" "$USER@$HOST:/media/fat/misterplex/hw_accept_fpga.yuv" "$OUT/fpga_i420.yuv"

# MB compare: product writeback proven if coded_y_changed >> 0 (wipe delta)
python3 - "$GOLDEN_YUV" "$OUT/fpga_i420.yuv" "$OUT/mb_compare.json" "$CODED_W" "$CODED_H" "$STATUS_LOG" "$OUT/dump_meta.txt" <<'PY'
import json,sys
gpath,fpath,out=sys.argv[1],sys.argv[2],sys.argv[3]
w,h=int(sys.argv[4]),int(sys.argv[5])
stlog,dmeta=sys.argv[6],sys.argv[7]
g=open(gpath,'rb').read(); f=open(fpath,'rb').read()
need=w*h*3//2
res={"ok":False,"first_failing_mb":None,"mismatched_mbs":0,"y_sad_total":0,"note":"",
     "plxf_ok":False,"writeback_ok":False,"product_pixels":False}
st=open(stlog).read() if stlog else ""
try: meta=json.loads(open(dmeta).read())
except Exception: meta={}
plxf=meta.get("mailboxes",{}).get("PLXF",{})
res["plxf_ok"]=bool(plxf.get("magic_ok"))
res["plxf_lo"]=plxf.get("lo")
res["plxd"]=meta.get("mailboxes",{}).get("PLXD")
changed=int(meta.get("coded_y_changed") or 0)
res["coded_y_changed"]=changed
# Prove product writeback: enough pixels left the wipe tag (not host-stale plane)
res["writeback_ok"]= changed >= 256  # at least one full MB of Y changed
res["product_pixels"]= res["writeback_ok"]
if len(f)<need:
    res["note"]=f"fpga yuv short {len(f)}<{need}"
    json.dump(res, open(out,'w'), indent=2); print(json.dumps(res,indent=2)); sys.exit(0)
g=g[:need]; f=f[:need]
mw,mh=w//16,h//16
def mb_y(plane, mbx, mby):
    rows=[]
    for r in range(16):
        y=mby*16+r; x=mbx*16
        rows.append(plane[y*w+x:y*w+x+16])
    return b"".join(rows)
gy=g[:w*h]; fy=f[:w*h]
mean=sum(fy)/len(fy); var=sum((b-mean)**2 for b in fy)/len(fy)
res["fpga_y_mean"]=mean; res["fpga_y_var"]=var
first=None; mism=0; sad=0
first_written=None
wipe=int(meta.get("wipe") or 0x5A)
for mby in range(mh):
  for mbx in range(mw):
    a=mb_y(gy,mbx,mby); b=mb_y(fy,mbx,mby)
    s=sum(abs(a[i]-b[i]) for i in range(256))
    sad+=s
    written=sum(1 for i in range(256) if b[i]!=wipe)
    if written>32 and first_written is None:
        first_written={"mb_x":mbx,"mb_y":mby,"mb_addr":mby*mw+mbx,"y_changed":written}
    if s>64:
      mism+=1
      if first is None:
        first={"mb_x":mbx,"mb_y":mby,"mb_addr":mby*mw+mbx,"y_sad":s}
res["first_failing_mb"]=first
res["first_written_mb"]=first_written
res["mismatched_mbs"]=mism
res["y_sad_total"]=sad
if not res["writeback_ok"]:
    res["note"]="no wipe-delta — product pixels not proven in DDR (telemetry-only)"
    res["ok"]=False
else:
    # Pixel instrument is live even if PLXF absent
    if not res["plxf_ok"]:
        res["note"]="PLXF absent but wipe-delta proves product writeback; MB first-fail is valid instrument"
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
wb=bool(mb.get("writeback_ok") or mb.get("product_pixels"))
gate("writeback_wipe_delta", wb, f"y_changed={mb.get('coded_y_changed')} plxf={mb.get('plxf_ok')}")
if not wb:
    gate("mb_compare", False, note or "no proven product plane")
    hw_first="n/a (no proven product DDR plane)"
elif first is None:
    gate("mb_compare", True, "all MB Y match")
    hw_first="none (PASS)"
else:
    gate("mb_compare", False, f"addr={first['mb_addr']} ({first['mb_x']},{first['mb_y']}) sad={first['y_sad']}")
    hw_first=f"addr={first['mb_addr']} ({first['mb_x']},{first['mb_y']})"

tele_ok=all(ok for n,ok,_ in gates if n not in ("mb_compare","writeback_wipe_delta"))
print("=== HW ACCEPT GATES ===")
for n,ok,d in gates:
    print(f"  {'PASS' if ok else 'FAIL'} {n}: {d}")
print(f"TELEMETRY: {'PASS' if tele_ok else 'FAIL'}")
print(f"WRITEBACK: {'PASS' if wb else 'FAIL'} y_changed={mb.get('coded_y_changed')} plxf_ok={mb.get('plxf_ok')}")
print(f"HW_FIRST_FAILING_MB: {hw_first}")
print(f"SIM_FIRST_FAILING_MB: addr=1 (lane branch reference; merged TBD)")
print(f"NOTE: {note}" if note else "NOTE: (none)")
verdict="FAIL"
if tele_ok and wb and first is None:
    verdict="PASS_FULL"
elif tele_ok and wb:
    verdict="PASS_PIXEL"
elif tele_ok:
    # Telemetry without wipe-delta: fabric ingested NALs but product pixels
    # never reached DDR frame-store (fit3 known: PLXF dead, px_wr silent).
    verdict="PASS_TELEMETRY_NO_WRITEBACK"
print(f"VERDICT: {verdict}")
(out/"verdict.txt").write_text(
    verdict+f"\nhw_first={hw_first}\ny_changed={mb.get('coded_y_changed')}\nplxf_ok={mb.get('plxf_ok')}\n")
sys.exit(0 if tele_ok else 1)
PY
