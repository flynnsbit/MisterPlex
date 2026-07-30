# Handoff: chroma WIP from sv-traverse (luma lane) → sv-mvd

**From:** worktree `.worktrees/rtl-real-ref-measure`, branch was `rtl/chroma-intra` (misnamed — luma lane).
**Base SHA for luma (do not discard):** `f8cfd85` — I16 AC max15 skip_dc + combined DC+AC idct; LUMA 227/300.
**Owner now:** sv-mvd (`w-mvd-mvp`). Traverse lane will **not** continue chroma.

## DO NOT merge this as-is into product without re-validation

### Critical defect observed: `mb_written=299`

When the full chroma sink path was live (extra ST_CHR_* states, DC-only finish, pred wait), real-ref sim reported:

```
I_RECON_DONE mb_written=299 blk_applied=5021
STORE_MB_BITMAP unique=299 dup=0 oob=0 expected=300 fault_dup=0
```

After stripping chroma back to luma-only sink @ `f8cfd85` path:

```
I_RECON_DONE mb_written=300
STORE_MB_BITMAP unique=300 dup=0 oob=0 expected=300
```

**Implication:** a chroma change can silently drop one MB store. sv-mvd must assert store coverage from day one.

### Reuse existing address bitmaps (do not reinvent)

Already in product/real-ref path (`stream_path` / full-frame TB logs):

- `STORE_MB_BITMAP unique=N dup=D oob=O expected=E fault_dup=F`
- `DELIVERED_MB_BITMAP unique=N dup=D oob=O expected=E fault_drop=F real_ref=R`

Gates in `tests/unit/test_stream_path_full_frame_compare.sh` require **unique==expected==300, dup==0** in both `USE_REAL_REF_COMMIT=0/1`, with RED twins:
- `FAULT_DROP_TRAV_MB` → unique drops
- `FAULT_DUP_STORE` → dup rises

**Wire chroma work so these still fire.** Prefer failing the gate over a silent 299.

### What this WIP claimed (from chroma_preregister.txt — verify yourself)

- Root cause notes: `pps_parser` ST_CHR was `u(1)` not `se(v)` for `chroma_qp_index_offset`; product `decode_stub` hardwired offset=0 while stream PPS offset=-2 → host QPc=25 vs RTL QPc=27.
- Claimed after fix: `f0 uv_mb_exact=224/300`, **HEADLINE intra=219/300** (luma held 227/300). **sv-mvd must re-measure from a clean base; do not trust this card without independent rerun.**
- Modules: `h264_chroma_qp.sv`, `h264_chroma_dc_hadamard_inv.sv`, sink chroma pred+residual, traverse `res_mb_chroma_mode`, PPS se(v) export.

### Files in this handoff directory

| Path | Role |
|------|------|
| `chroma-wip-tracked.diff` | git diff of all tracked dirty files vs `f8cfd85` |
| `h264_chroma_qp.sv` | untracked new module |
| `h264_chroma_dc_hadamard_inv.sv` | untracked new module |
| `test_p3_chroma_dc_hadamard*` | unit TB stubs |
| `chroma_preregister.txt` | pre-register / claimed measure notes |

### Luma lane continues without these files

After handoff, traverse worktree resets to `f8cfd85` clean (plus branch rename to `rtl/i-slice-luma`). Chroma sources deleted from this tree.
