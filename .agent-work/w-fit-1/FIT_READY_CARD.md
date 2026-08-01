# Fit-ready card — no fit authorised

**Branch:** `w-fit-integ-c5382bee-dequant-swap` @ see `git rev-parse HEAD`  
**Updated:** 2026-08-01 (parent re-scope: no cadence RTL; post-fit pre-staged)

## Static gates (this session)

| Gate | true rc | Note |
|------|--------:|------|
| `make define-parity` | **0** | PASS |
| `make quartus-sv-subset` | **0** | + verilator-elab PASS |
| `make unit` | **0** | GATE_SKIP inventory only (PMS KEY missing; rc=77 wrapper) — not scored as pass |

Capture pattern: `make <target>; echo "true rc=$?"` (never through a pipe).

## Post-fit invocations (ready the moment a fit exists)

```bash
# Hierarchy — critical modules must survive fitting
make post-fit-hierarchy \
  FIT_RPT=path/to/Plex.fit.rpt \
  MAP_RPT=path/to/Plex.map.rpt \          # optional
  COMPILE_LOG=path/to/compile.log         # optional
# true rc=$?

# Timing — any negative setup/hold slack = hard fail
make post-fit-timing STA_RPT=path/to/Plex.sta.rpt
# true rc=$?

# Optional margin vs assets/timing_margin_baseline.json
make post-fit-timing-margin STA_RPT=path/to/Plex.sta.rpt
# true rc=$?  (ABSENT/malformed STA => rc=77 ≠ pass)

# Optional exclusion audit
make timing-exclusion STA_RPT=path/to/Plex.sta.rpt
```

**Smoke (this tree):**

| Input | Gate | true rc | Meaning |
|-------|------|--------:|---------|
| (no FIT_RPT) | hierarchy | **2** | arg required |
| (no STA_RPT) | timing | **2** | arg required |
| `fake_timing_red.sta.rpt` | timing | **2** | negative slack REJECTED (gate works) |
| `fake_fit_red.rpt` | hierarchy | **1**→make **2** | under-size REJECTED |
| `fake_fit_green.rpt` | hierarchy | **1**→make **2** | fixture incomplete (missing present_core/stream_path) — **not** a product green |
| `remote_out/slot11/Plex.fit.rpt` | hierarchy | **0** | scripts parse real fit.rpt |
| `remote_out/slot11/Plex.sta.rpt` | timing | **2** | **negative setup** on general[0]/[2] — **do not treat slot11 STA as BUILD_OK** |

Parent product baseline (c5382bee class): setup **+0.165** / hold **+0.245** — any new RBF must clear post-fit-timing with **no negative rows**.

## Deploy after BUILD_OK (parent owns device)

1. Check NEW_RBF md5 ∉ banned `{8832824e,75da8bb1,4d6ee356,4deaf6cc,dabdaeb0}` + do-not-ship `{9eb1431a,ff2e3ca3,f0d3a385,2890baac,…}`  
2. **ONE** `DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh`  
3. FBAR reconfirm → hard residual  
4. Only then next exclusive  

## Branch audit — what would waste a slot

| Content | Measurement-backed to deploy? | Action |
|---------|-------------------------------|--------|
| **Judder / present_cadence 3:2** | **No** — parent: not established defect; r-misterfin: cadence does not drive DDR swaps | **Do not change** until w-geom fabric histogram |
| `present_cadence.sv` vs main | Only **width-extend** mul/div (`{24'd0,cf}`) — not a 3:2 policy change | Keep; not a judder “fix” |
| 907e swap_pending hold | Latent NBA; freeze TB class exists; **not** proven cause of 10.3% 4–5 plateaus | Ride **only if** w-geom proves skip/swap defect |
| −32 DSP dequant + thruput RMW | Sim bit-exact/cy/MB only; **no silicon decode product path** | Area/direct-play prep — **not** sole fit justification |
| Chrome post-scale plane | Paper design only (`docs/chrome-post-scale-plane-design.md`) | No RTL in fit bundle yet |
| Hybrid fail-closed stream_path | Safety; product_recon_ok=0 | OK to ship with tip; does not fix judder |
| Untracked `*.i420` under evidence | Binary junk | **Do not commit** |
| Stale `integ/fit4|fit5|rtl-consol` | Jul-29 | **Not** merge bases |

**Largest risk if fitted now:** thruput/decode RTL volume (`h264_p_mb_traverse`, sink RMW, etc.) without a measured product defect → RBF nobody should deploy over working video path.

## No cadence RTL

Explicit: **no** `present_cadence` policy change prepared. DDR swap path remains async vsync re-latch (`ddr_frame_store` `swap_pending && pending_ready_s2`).
