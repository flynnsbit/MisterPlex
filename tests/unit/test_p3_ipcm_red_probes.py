#!/usr/bin/env python3
"""RED mutation probes for h264_ipcm_passthrough.

Each probe injects a specific bug into the RTL and verifies that the test
DETECTS it (exits non-zero). A test that cannot detect a mutation is degenerate.

Mutations:
1. wrong_luma_offset: Luma samples start at index 1 instead of 0 (off-by-one)
2. wrong_cb_boundary: Cb starts at 255 instead of 256 (boundary error)
3. missing_done: Done never asserts (control logic bug)
4. corrupt_data: XOR all data with 0x01 (data integrity failure)
"""
import subprocess, sys, os, tempfile, shutil

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "../.."))
RTL_SRC = os.path.join(ROOT, "fpga/Plex_MiSTer/rtl/h264_intra_pred.sv")
TB_SRC = os.path.join(SCRIPT_DIR, "rtl/p3_ipcm_tb.sv")
TEST_SRC = os.path.join(SCRIPT_DIR, "test_p3_ipcm_verilator.cpp")

VERILATOR = os.environ.get("VERILATOR",
    os.path.expanduser("~/.local/oss-cad-suite-20260726/bin/verilator"))
if not os.path.isfile(VERILATOR):
    alt = os.path.expanduser("~/.local/oss-cad-suite/bin/verilator")
    if os.path.isfile(alt):
        VERILATOR = alt
    else:
        print("ERROR: Verilator not found", file=sys.stderr)
        sys.exit(2)

MUTATIONS = {
    "wrong_luma_offset": {
        "original": "luma_out[count[7:0]] <= wr_data;",
        "mutated":  "luma_out[count[7:0] + 8'd1] <= wr_data;",
        "desc": "Off-by-one in luma index — shifts all luma samples by one position"
    },
    "wrong_cb_boundary": {
        "original": "else if (count < CB_END)",
        "mutated":  "else if (count < LUMA_END - 9'd1)",
        "desc": "Cb boundary at 255 instead of 256 — last luma byte goes to Cb"
    },
    "missing_done": {
        "original": "done <= 1'b1;",
        "mutated":  "done <= 1'b0;  // BUG: done never asserts",
        "desc": "Done signal never asserts — module appears hung"
    },
    "corrupt_data": {
        "original": "luma_out[count[7:0]] <= wr_data;",
        "mutated":  "luma_out[count[7:0]] <= wr_data ^ 8'h01;",
        "desc": "XOR luma with 0x01 — subtle single-bit corruption"
    },
}

def run_mutation(name, info):
    build_dir = os.path.join(ROOT, f"build/obj_ipcm_red_{name}")
    if os.path.exists(build_dir):
        shutil.rmtree(build_dir)

    # Read original RTL
    with open(RTL_SRC) as f:
        rtl = f.read()

    if info["original"] not in rtl:
        print(f"ERROR {name}: original pattern not found in RTL", file=sys.stderr)
        return False

    # Apply mutation
    mutated_rtl = rtl.replace(info["original"], info["mutated"], 1)
    mut_file = os.path.join(build_dir + "_src.sv")
    os.makedirs(os.path.dirname(mut_file), exist_ok=True)
    with open(mut_file, "w") as f:
        f.write(mutated_rtl)

    # Build
    cmd_build = (
        f"{VERILATOR} --cc {TB_SRC} {mut_file} "
        f"--exe {TEST_SRC} --Mdir {build_dir} "
        f'-CFLAGS "-std=c++17 -O2" --top-module p3_ipcm_tb -Wno-fatal'
    )
    r = subprocess.run(cmd_build, shell=True, capture_output=True, text=True)
    if r.returncode != 0 and "Error" in r.stderr and "Warning" not in r.stderr.split("Error")[0][-20:]:
        # Verilator error is acceptable for some mutations (compile-time detect)
        print(f"RED PASS {name}: mutation detected at compile time (verilator error)")
        print(f"  — {info['desc']}")
        os.remove(mut_file)
        return True

    # Make
    mk_file = os.path.join(build_dir, "Vp3_ipcm_tb.mk")
    if not os.path.isfile(mk_file):
        print(f"FAIL {name}: no makefile generated", file=sys.stderr)
        os.remove(mut_file)
        return False

    r = subprocess.run(f"make -C {build_dir} -f Vp3_ipcm_tb.mk -j$(nproc)",
                       shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"RED PASS {name}: mutation detected at build time (compile error)")
        print(f"  — {info['desc']}")
        os.remove(mut_file)
        shutil.rmtree(build_dir, ignore_errors=True)
        return True

    # Run
    exe = os.path.join(build_dir, "Vp3_ipcm_tb")
    r = subprocess.run(exe, capture_output=True, text=True, timeout=30)
    os.remove(mut_file)
    shutil.rmtree(build_dir, ignore_errors=True)

    if r.returncode != 0:
        print(f"RED PASS {name}: mutation detected (rc={r.returncode})"
              f" — {info['desc']}")
        return True
    else:
        print(f"RED FAIL {name}: mutation NOT detected — test is blind to this bug",
              file=sys.stderr)
        print(f"  Mutation: {info['desc']}", file=sys.stderr)
        print(f"  Output: {r.stdout[:200]}", file=sys.stderr)
        return False


all_pass = True
for name, info in MUTATIONS.items():
    if not run_mutation(name, info):
        all_pass = False

print()
if all_pass:
    print(f"All {len(MUTATIONS)} RED probes detected. Test catches all mutation classes.")
else:
    print("SOME RED PROBES FAILED — test has blind spots", file=sys.stderr)
    sys.exit(1)
