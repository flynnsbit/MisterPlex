#!/usr/bin/env bash
# Red-before-green arithmetic gate for ascal-native 960×540 beam class.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - <<'PY'
F = 20_000_000
H_DE, V_ACT = 960, 540

def check(name, ht, vt, fps_lo, fps_hi, hblank_min, vblank_min):
    assert ht > H_DE and vt > V_ACT, name
    hb, vb = ht - H_DE, vt - V_ACT
    fps = F / (ht * vt)
    act = H_DE * V_ACT * fps / 1e6
    print(f"{name}: HT={ht} VT={vt} fps={fps:.4f} Hblank={hb} Vblank={vb} act_mpix={act:.3f}")
    assert fps_lo <= fps <= fps_hi, f"{name} fps {fps}"
    assert hb >= hblank_min, f"{name} hblank {hb}"
    assert vb >= vblank_min, f"{name} vblank {vb}"
    assert act < 20.0, f"{name} act {act} exceeds 20 Mpix/s CE=1"
    # legacy serialize wall only applies MULTI_PIXEL serialize — 1px path peak=20
    assert act < 20.0
    return act

# Primary 30 Hz
a30 = check("30A_primary", 1182, 564, 29.95, 30.05, 200, 20)
# Alternate
check("30B_alt", 1190, 560, 29.95, 30.05, 200, 16)
# Film 24
check("24_film", 1389, 600, 23.90, 24.10, 400, 48)

# Exact product identity
assert 1182 * 564 == 666648
assert abs(F / 666648 - 30.0008) < 1e-3

# 15.55 vs ceilings
assert abs(a30 - 15.552) < 0.02
print("OK: 15.55 Mpix/s < 20 (1px) — B1 wide-FIFO NOT required for ascal-native 1px path")
print("OK: 15.55 > 13.33 — B1 WOULD be required only if serialize PPC path enabled")

# 640x360@30 budget
act360 = 640 * 360 * 30 / 1e6
print(f"640x360@30 act_mpix={act360:.3f}")
assert act360 < 20.0
print("PASS test_present_beam_960_arith")
PY

# Ensure RTL file exists and quotes primary constants
grep -q "1182" "$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv"
grep -q "564" "$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv"
# stale log must not exist
test ! -f "$ROOT/.agent-work/w-clock/npx_full_raster_run.txt"
echo "PASS test_present_beam_960_arith (shell)"
exit 0
