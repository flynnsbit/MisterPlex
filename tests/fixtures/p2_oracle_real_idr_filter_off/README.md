# Same-byte real-content IDR, legally encoded filter-off

This fixture freezes the controller owner's `build/p2-intra-controller/filteroff.264`
for an independent **full stream_path** check. The producer reports ordinary
decoding of `p3_host_recon/plex_real_baseline_320x240_1f.264`, then libx264 baseline
QP24 with `no-deblock=1`. It is a local re-encode of existing real-content fixture
bytes, not a new PMS capture and not a slice-header patch.

The original source bytes and their README are hash-bound and retained in the
selected-input snapshot via `provenance.json`. Their historical nofilter/MB0
scores are **not** references for this gate. The original notice remains at
[`../p3_host_recon/README.md`](../p3_host_recon/README.md).

```sh
tests/unit/run_gop12_fpga_sim.sh --source-pin worktree --frames 1 \
  --fixture tests/fixtures/p2_oracle_real_idr_filter_off/real_color_320x240_1f.264
```

Ordinary FFmpeg decoding uses unchanged defaults. Independently parsed headers
must confirm encoded `disable_deblocking_filter_idc=1`. Only compressed bytes
enter the RTL; native Y/U/V are observed from actual accepted writes, never
prefilled. New-controller completion also requires real reference promotion,
no decode/reference error, and 76,800 accepted RGB output writes.

An exact result is a single-frame decoder/integration result only: it does not
prove temporal reference reuse, P pictures, filter-on support, throughput, Plex,
HDMI presentation, or hardware acceptance.
