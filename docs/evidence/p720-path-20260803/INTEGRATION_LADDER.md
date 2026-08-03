# w-path integration ladder (parent broadcast 2)

**Branch tip:** `aec131d1` (`w-path-720p`)  
**Pinned truth:** main GREEN at parent-verified commits; do not claim L4 without all four fields.  
**Rule:** ONLY L4 is in the product. L0–L3 are not shipped.

Ladder:
- L0 written (exists on some branch)
- L1 ON_MAIN
- L2 IN_FILES_QIP
- L3 INSTANTIATED
- L4 ENABLED (macro/param on)

## Path-owned RTL

| Module | ON_MAIN | IN_FILES_QIP | INSTANTIATED | ENABLED | Level | Notes |
|--------|---------|--------------|--------------|---------|-------|-------|
| `host_bank_ingest_credit.sv` | **no** | **no** | **no** | **no** | **L0** | Route-A HPS credit card. On branch only. Not needed for Route-B DP+ascal 720 glass. **Do not land until parent sequences** — avoid 47-module pile-up. To reach L4: merge → files.qip → instantiate under `Plex.sv` ingest path → enable with named param default-off then lab-on. |

Evidence commands (branch worktree, not live main mid-land):

```bash
test -f fpga/Plex_MiSTer/rtl/host_bank_ingest_credit.sv && echo L0=yes
git cat-file -e main:fpga/Plex_MiSTer/rtl/host_bank_ingest_credit.sv 2>&1 || echo ON_MAIN=no
rg host_bank_ingest_credit fpga/Plex_MiSTer/files.qip || echo IN_QIP=no
rg host_bank_ingest_credit fpga/Plex_MiSTer/Plex.sv || echo INSTANTIATED=no
```

## Path-owned host software (not QIP — binary product ladder)

Host is not `files.qip`. Analog for honesty:

| Unit | ON_MAIN | IN_DAEMON_BUILD (branch) | WIRED_HOT_PATH (branch) | DEFAULT_ON (branch) | Level vs main |
|------|---------|--------------------------|-------------------------|---------------------|---------------|
| `ddr_frame_layout.hpp` pad426 + LEG pin + B20 pack | **no** | yes | yes | yes | **L0** until merge |
| `plxg_record.hpp` seqlock helpers + B20 store oracle | **no** | yes | yes (via fpga_spi) | yes | **L0** |
| `ddr_present_bank.hpp` capacity PLXG plan | **no** | yes | yes | yes | **L0** |
| `fpga_spi.cpp` writePlxgRecord + coupled kick | **no** | yes | yes | yes | **L0** |
| `plex_resolve.cpp` DP default + Route-B ≤960×540 | **no** | yes | yes | yes | **L0** |
| `media_player.cpp` plan-trust vs measured | **no** | yes | yes | yes | **L0** |
| `main.cpp` DP setDecodeSize(content) | **no** | yes | yes | yes | **L0** |
| `ffmpeg_vf.hpp` pad-only 426→432 | **no** | yes | yes | yes | **L0** |
| `h264_fabric_stream_gate.hpp` byte CB gate | **no** | yes | yes | yes | **L0** |
| `pms_delivery_geom.hpp` Route-B caps | **no** | yes | yes | yes | **L0** |

**Honest aggregate:** entire p720-path host stack is **L0 relative to main** (feature-complete on branch, unit-green, **not merged**). After parent merge it becomes product without a separate QIP step — still need parent HW proof for device behavior.

## Shared product pins (observed on this branch tree; not path-owned)

| Pin | Branch observation | Product impact |
|-----|--------------------|----------------|
| `Plex.sv` `.use_frame_store(1'b0)` | present | frame store **DISABLED** (L3 missing for store path) |
| `Plex.qsf` `FRAME_W=640` `FRAME_H=480` | present | still 480p canvas macros |
| `PRESENT_BEAM_960` | commented / off | beam not 960 |
| 720p present modules | owned by w-osd | parent: some L2 dead / L3–L4 in flight on main — **not path claims** |

## What landing would take (path)

1. **Host stack:** parent sequences merge of `w-path-720p` (or cherry-picks) onto green main after rebase. No QIP. Risk: hot-path PLXG/doorbell couple + Route-B caps + DP plan-trust.
2. **`host_bank_ingest_credit.sv`:** defer unless Route-A zero-copy is scheduled. Ladder L0→L4 needs parent slot; not a silent drive-by instantiate.
3. **B20 store match / applied_seq / w-clock store-applied:** **w-mem / w-clock** RTL — path only owns host doorbell pack + contract oracle (still L0 until host merge).

## What path will NOT claim

- "Integrated PLXG/present" without per-module L0–L4 fields.
- L4 for any RTL path does not own or has not enabled.
- Device/fit results (parent-only).

## Status line

`w-path aec131d1 ladder: host stack L0 (branch unit-green); host_bank_ingest_credit L0/L0/L0/L0; B20 store/clock RTL-owed; no unilateral main land`
