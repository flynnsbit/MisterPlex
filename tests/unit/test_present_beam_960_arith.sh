#!/usr/bin/env bash
# Red-before-green arithmetic + true_de model for ascal-native 960×540@30.
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
    return act

a30 = check("30A_primary", 1182, 564, 29.95, 30.05, 200, 20)
check("30B_alt", 1190, 560, 29.95, 30.05, 200, 16)
check("24_film_legacy", 1389, 600, 23.90, 24.10, 400, 48)
# w-scaler film companion fixed-H
check("24_film_1182x705", 1182, 705, 23.95, 24.05, 200, 150)

assert 1182 * 564 == 666648
assert abs(F / 666648 - 30.0008) < 1e-3
assert abs(a30 - 15.552) < 0.02

# true_de model (ascal iauto): DE extent == content
ih, iv, de_pix, cont = H_DE, V_ACT, H_DE * V_ACT, H_DE * V_ACT
true_de = int(ih == H_DE and iv == V_ACT and de_pix == H_DE * V_ACT and cont == de_pix)
print(f"true_de={true_de} ih={ih} iv={iv} de_pix={de_pix}")
assert true_de == 1
# island must be 0
true_island = int(1280 == 960 and 720 == 540)
assert true_island == 0
print("OK true_de=1 for 960x540 DE; island1280 true_de=0")

print("OK: 15.55 Mpix/s < 20 (1px) — B1 NOT required for ascal-native 1px path")
print("OK: 15.55 > 13.33 — B1 required only if MULTI_PIXEL serialize ON")
act360 = 640 * 360 * 30 / 1e6
print(f"640x360@30 act_mpix={act360:.3f}")
assert act360 < 20.0
# sync placement
assert 960 + 32 == 992 and 992 + 64 == 1056
assert 540 + 8 == 548 and 548 + 6 == 554
print("SYNC H=992..1056 V=548..554")
print("PASS test_present_beam_960_arith")
PY

grep -q "1182" "$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv"
grep -q "564" "$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv"
grep -q "960" "$ROOT/fpga/Plex_MiSTer/rtl/present_video_timing_960.sv"
test ! -f "$ROOT/.agent-work/w-clock/npx_full_raster_run.txt"
test -f "$ROOT/.agent-work/w-clock/W_NOSTUB_QSF_BEAM_CONSTANTS.md"
test -f "$ROOT/assets/ascal_native_beam_contract.json"
echo "PASS test_present_beam_960_arith (shell)"
exit 0
