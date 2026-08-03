# w-path integration ladder (broadcast 2 + parent retraction)

**Measured from worktree:** branch **w-path-720p**  
**Branch SHA at doc commit:** see `git rev-parse --short HEAD`  
**Authority main for fleet truth:** **`origin/main`**, not local `main` (local main may be ahead with unpushed lands).

## Measurement identity (mandatory)

| Label | Ref | SHA (measure time) | How measured |
|-------|-----|--------------------|--------------|
| path branch | `w-path-720p` | this worktree HEAD | worktree files |
| fleet main | `origin/main` | **85bef583** | `git show origin/main:…` blobs only |
| parent-cited main | `ad928cb1` | ad928cb1 | pinned commit blobs |
| local `main` (not fleet truth) | `main` | **035fae51** in this clone | ahead of origin — w-osd merges local only |

```text
# origin/main@85bef583: present_*720p FILE=no QIP=no; host_bank FILE=no
# ad928cb1: files.qip ~33 SV lines; present_* FILE=no QIP=no  (matches parent retraction)
# local main@035fae51: HAS present_* in QIP — NOT fleet main; ignore for ON_MAIN claims
```

**Parent retraction accepted:** 720p present modules are **not** on fleet main.  
Prior parent “34→45 / L2 dead code on main@ad928cb1” was **false** (wrong tree).  
**IF any path plan assumed dead-code instantiation on main: REVERTED — no such work.**

## Path-owned RTL

| Module | Ref measured | ON_MAIN | IN_FILES_QIP | INSTANTIATED | ENABLED | Level |
|--------|--------------|---------|--------------|--------------|---------|-------|
| `host_bank_ingest_credit.sv` | origin/main@85bef583 | **no** | **no** | **no** | **no** | absent |
| `host_bank_ingest_credit.sv` | w-path-720p@HEAD | n/a | **no** | **no** | **no** | **L0** |

Route-A only. Not Route-B critical. **No land / no instantiate** until parent sequences.

## 720p present path (not path-owned — status only, pinned)

| Module | origin/main@85bef583 file | IN_QIP | INST | EN | Level |
|--------|---------------------------|--------|------|-----|-------|
| present_video_timing_720p | no | no | 0 | no | **absent on fleet main** |
| present_content_window | no | no | 0 | no | absent |
| present_geom_latch | no | no | 0 | no | absent |
| present_beam_content_de | no | no | 0 | no | absent |
| plex_present_geom_mux | no | no | 0 | no | absent |

Owner: **w-osd** (in flight on their branch). Path does **not** hunt “dead QIP” on main.

## Path-owned host software vs origin/main@85bef583

Host is not QIP. Entire p720-path host stack is **unmerged = L0** vs fleet main.

| Unit | ON_MAIN | Branch wired | Level |
|------|---------|--------------|-------|
| ddr_frame_layout / pad426 / B20 pack | no | yes | **L0** |
| plxg_record / B20 N→N+1 oracle | no | yes | **L0** |
| fpga_spi writePlxgRecord + coupled kick | no | yes | **L0** |
| plex_resolve DP + Route-B ≤960 | no | yes | **L0** |
| media_player plan-trust | no | yes | **L0** |
| main.cpp DP content decode size | no | yes | **L0** |
| ffmpeg_vf pad-only 426 | no | yes | **L0** |
| h264_fabric_stream_gate | no | yes | **L0** |

## Plan impact of retraction

| Decision | Action |
|----------|--------|
| “Instantiate dead L2 present modules on main” | **Never started; will not start** |
| Path host work | **Unchanged** — branch unit-green L0 |
| host_bank land | **Still deferred** |
| Trust local `main` for ON_MAIN | **No** — use origin/main or pinned SHA |

## Status line

`w-path ladder: host L0 vs origin/main@85bef583; host_bank L0; 720p present absent on fleet main (retraction); no L4; no dead-code hunt`
