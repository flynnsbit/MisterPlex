# Parent: ONE-SHOT DDR cache-policy probe

**Bench:** `tools/ddr_write_bench.cpp` on branch `w-bw`  
**Binary:** static armhf `build/arm/ddr_write_bench`  
**Worker does NOT run these.** Parent owns 192.168.1.183.

## Pre-registered predictions (BEFORE device run) — ON RECORD

| path | predicted MiBps | hit if |
|------|----------------:|--------|
| `/dev/mem` product (O_SYNC write 480p) | **50–70** | uncached-class |
| write-through class | **≥800** | would refute uncached-class |
| `/dev/fb0` control | **UNKNOWN** | measure only; not frame-store phys |

Prior archive (not this run): `W-FEED-arm-profile-ORIGINAL.txt` 624×480 O_SYNC MiBps=58.074.  
MiSTerFin 60 MB/s vs 1.5 GB/s is **NOT** our measurement.

## Single paste (host → device)

Prefer **misterplexd stopped** for the few seconds of the matrix (payload write, **no doorbell**). Daily driver: do not thrash SPI/load_core.

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-bw && \
make arm-ddr-bench && \
sshpass -p "${MISTER_PASS:-1}" scp -o StrictHostKeyChecking=no \
  build/arm/ddr_write_bench \
  "root@${MISTER_HOST:-192.168.1.183}:/media/fat/misterplex/bin/ddr_write_bench" && \
sshpass -p "${MISTER_PASS:-1}" ssh -o StrictHostKeyChecking=no \
  "root@${MISTER_HOST:-192.168.1.183}" \
  'B=/media/fat/misterplex/bin/ddr_write_bench; chmod +x "$B"; "$B" --matrix --loops 1000 --bank 0; echo true_rc=$?'
```

Equivalent helper: `scripts/parent_ddr_cache_probe.sh` (parent only).

## Expected output (parseable keys)

```
ddr_write_bench_meta ... prereg_devmem_mibps_lo=50 prereg_devmem_mibps_hi=70 prereg_writethrough_mibps_lo=800 ...
matrix_safety phys_base=0x30000000 ... doorbell_kick=0 ...
devmem_map case=devmem_sync_480 phys=0x30000000 ... doorbell_NOT_written=1
smaps_tag=devmem_sync_480 VmFlags: ...    # look for token "dc"
ddr_write_bench path=devmem_sync_480 rw=write ... MiBps=NNN.NNN ...
... (nosync, nosync_flush, sync_240, read_240, read_480, fb0) ...
matrix_case path=devmem_sync_480 rw=write MiBps=NNN.NNN rc=0
matrix_score product_sync_480 MiBps=NNN.NNN score=HIT_uncached_class_50_70|HIT_writethrough_class_ge_800|...
matrix_summary_end worst_rc=0
matrix_done true_rc=0
true_rc=0
```

## Scoring

1. `VmFlags` contains `dc` → kernel don't-cache token (supporting uncached/device class).  
2. `matrix_score ... HIT_uncached_class_50_70` → HIT pre-reg; MISS write-through.  
3. `HIT_writethrough_class_ge_800` → HIT WT-class; re-open transport theory at 720p.  
4. fb0 `smem_start` ≠ `0x30000000` → fb route cannot replace frame-store map without a new driver.

Paste full stdout back to w-bw for hit/miss publish.

## Safety

- Maps only `0x30000000` + layout `map_bytes` (two banks + doorbell **page**).  
- Writes **bank payload only**; never doorbell magic; never SPI.  
- `--fb-copy` writes `/dev/fb0` control surface only (restores 4 KiB black strip).  
- See `CACHEABILITY_AND_PRESENT.md` before any mapping redesign (`PRESENT=fpga|both` / `initPresent`).

## Host gates (no device)

```bash
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-bw
python3 tests/unit/test_ddr_bw_contracts.py; echo "true rc=$?"
python3 tests/unit/test_ddr_scanout_budget.py; echo "true rc=$?"
python3 tests/unit/test_ddr_playback_contention.py; echo "true rc=$?"
python3 tests/unit/test_ddr_dram_bank_map.py; echo "true rc=$?"
make arm-ddr-bench; echo "true rc=$?"
```
