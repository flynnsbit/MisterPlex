# Glass baseline pair — v0.2.0 floor

**Role:** regression **floor** for eyes-on HDMI glass.  
**Validated:** 2026-08-11 (USB MacroSilicon grabber) — B6 RealGlass content identity + idle chevron.

| Piece | md5 | File in this directory |
|-------|-----|------------------------|
| `Plex.rbf` | `dfebf2bfd08dd70b473b587dd7e81848` | `Plex.rbf` |
| `misterplexd` | `7cd10b4d438c714a9b8c4766dc982d59` | `misterplexd` |

Machine contract: `tests/fixtures/glass_baseline/pair.json`  
Human history / gap analysis: `docs/glass-baseline-pair.md`  
Live gate: `tests/hw/test_glass_baseline_pair.sh`

## Restore on device

```bash
# From repo root (host)
RBF=release_artifacts/v0.2.0-glass-baseline/Plex.rbf
D=release_artifacts/v0.2.0-glass-baseline/misterplexd
sshpass -p "${MISTER_PASS:-1}" scp -o StrictHostKeyChecking=no \
  "$RBF" root@${MISTER_HOST:-192.168.1.183}:/media/fat/_Utility/Plex.rbf
sshpass -p "${MISTER_PASS:-1}" scp -o StrictHostKeyChecking=no \
  "$D" root@${MISTER_HOST:-192.168.1.183}:/media/fat/misterplex/bin/misterplexd
# Also keep pins:
#   /media/fat/_Utility/Plex.GOODBASELINE.dfebf2bf.rbf
#   /media/fat/misterplex_v2/bin/misterplexd.GOODBASELINE.7cd10b4d

# Conf (minimum): PRESENT=fpga (or both), DECODE=320x240, STREAM=0, IDLE_SCREEN=logo
# Menu bounce → start misterplexd → tests/hw/test_glass_baseline_pair.sh
```

## Policy

A **new** `misterplexd` + `Plex.rbf` pair does **not** need these md5s.  
It **must** pass the same behavioral glass gates (or better) before replacing this floor as the lab default.
