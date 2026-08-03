#!/usr/bin/env python3
import glob, sys, time
mpid = int(sys.argv[1])
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 45.26
HZ = 100.0

def proc_j():
    st = open(f"/proc/{mpid}/stat").read().split()
    return int(st[13]) + int(st[14])

def tid_map():
    m = {}
    for p in glob.glob(f"/proc/{mpid}/task/*/stat"):
        raw = open(p).read()
        rp = raw.rfind(")")
        rest = raw[rp + 2 :].split()
        tid = int(raw.split()[0])
        ut, stt = int(rest[11]), int(rest[12])
        start = int(rest[19])
        m[tid] = (ut + stt, rest[0], start)
    return m

w0 = time.time()
j0 = proc_j()
t0 = tid_map()
time.sleep(secs)
w1 = time.time()
j1 = proc_j()
t1 = tid_map()
du = w1 - w0
dm = j1 - j0
P = 100.0 * dm / (HZ * du)
hyb = 200.0 * dm / (HZ * du)
print(f"PLAY_WALL_S={du:.3f}")
print(f"PLAY_DJ={dm}")
print(f"PLAY_P_ONECPU={P:.3f}")
print(f"PLAY_HYB_200DJ={hyb:.3f}")
rows = []
for tid, a in t1.items():
    b = t0.get(tid)
    dj = a[0] - (b[0] if b else 0)
    rows.append((dj, tid, a))
rows.sort(reverse=True)
print("PLAY_TID_BEGIN")
for dj, tid, a in rows[:12]:
    print(f"tid={tid} dj={dj} rate={100 * dj / (HZ * du):.3f} state={a[1]} start={a[2]}")
print("PLAY_TID_END")
logp = "/media/fat/misterplex/misterplexd.log"
try:
    lines = open(logp).read().splitlines()
    for l in [x for x in lines if "media: frames=" in x][-5:]:
        print("FRAME", l)
    for l in [x for x in lines if ("playMedia" in x or "testsrc" in x)][-8:]:
        print("PLAYLOG", l)
except Exception as e:
    print("log_err", e)
