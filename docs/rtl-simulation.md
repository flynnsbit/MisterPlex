# RTL simulation

MiSTerPlex has a userspace Verilator path for behavioural RTL checks before paying for a Quartus fit. The default local install is outside the repo:

```bash
export OSS_CAD_SUITE="$HOME/.local/oss-cad-suite"
scripts/run_verilator.sh --version
```

Do not source `~/.local/oss-cad-suite/environment` globally and do not prepend the suite to your login `PATH`; that can shadow normal host/Quartus tools. `scripts/run_verilator.sh` scopes `PATH="$OSS_CAD_SUITE/bin:$PATH"` to the single Verilator process only. The unit harness uses that wrapper, which checks `$VERILATOR`, then `$OSS_CAD_SUITE/bin/verilator`, then `verilator` on the existing `PATH`.

## Built-in H.264 IQ/IDCT/recon simulation

Run just the RTL sim:

```bash
make rtl-sim
# or
VERILATOR=$HOME/.local/oss-cad-suite/bin/verilator tests/unit/test_p3_idct_rtl_sim.sh
scripts/run_verilator.sh --version
```

`make unit` invokes the same script. If Verilator is absent it prints a loud `SKIP RTL SIM` notice and exits 0 so non-simulator hosts keep their host tests usable; that skip is not a hardware-quality pass.

The current test elaborates `fpga/Plex_MiSTer/rtl/h264_iq_idct_4x4.sv` with Verilator and drives all 16 luma 4x4 blocks from `tests/fixtures/p3_host_recon/mb0_luma_v1.json`. It compares actual RTL `dequant`, `idct`, and `recon` outputs against the checked-in golden JSON.

## Simulating another module

Create a C++ testbench under `tests/rtl/` that includes the generated `V<top>.h`, drives ports, calls `eval()`, and checks outputs. Then run:

```bash
ROOT=$PWD
TOP=my_top_module
mkdir -p build/verilator/$TOP
scripts/run_verilator.sh --cc --exe --build \
  --Mdir build/verilator/$TOP \
  --top-module $TOP \
  -CFLAGS "-std=c++17 -O2" \
  fpga/Plex_MiSTer/rtl/my_top_module.sv tests/rtl/my_top_module_tb.cpp
build/verilator/$TOP/V$TOP
```

For multi-file RTL, list every required `.sv` on the Verilator command line or use `-f filelist.f`. Keep generated outputs under `build/verilator/`.
