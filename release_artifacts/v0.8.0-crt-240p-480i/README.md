# MiSTerPlex v0.8.0 — CRT 15 kHz siblings (draft)

**ascal 15 kHz `video_mode` is RED.** HDMI grabber black / `hw_presents=unavailable`
(240p bob) or interlaced chevron (480i weave) is not a CRT 24 fps PASS. A TV
CRT on the VGA RGB port needs sibling present-beam RBFs, not ascal.

This folder is a **template**. No RBF hashes yet. **BUILD_OK is not claimed.**
`Plex_240p15.rbf`, `Plex_480i.rbf`, `misterplexd.240p15`, and `misterplexd.480i`
are not here. `scripts/install_paired_crt.sh` exits **2** until they land.

Digital 24 fps pairs (v0.7.0) stay GOLD and must not be thrashed:

| File | Id |
|------|----|
| `Plex_480p.rbf` | md5 `07f54d9f…` |
| `misterplexd.480p` | sha256 `acfa03d7…` |
| `Plex_720p24.rbf` | md5 `03f1b95a…` |
| `misterplexd.720p24` | sha256 `437e330d…` |

CRT install never overwrites those four names.

## Intended fabric beams (clk_sys stays 20 MHz)

| Sibling | Raster | CE | H / V | Present |
|---------|--------|----|-------|---------|
| **240p15** | 424×262 | CE/3 | ~15.723 kHz / ~60.012 Hz | bob (even store x/y of 640×480) |
| **480i** | 849×262 field | CE 2/3 | ~15.705 kHz / ~59.942 field | weave (even/odd store rows) |

Store stays 640×480 @ doorbell `0x300FF000`. Do not use the dead 320×240
doorbell. Do not raise `clk_sys` on product `Plex.qsf` (L52).

## How to load (once BUILD_OK exists)

Menu → **`_Utility/Plex_240p15`** or **`_Utility/Plex_480i`**.

The watcher (`scripts/misterplex_core_watch.sh`) selects the daemon by **RBF
md5** from `rbf_daemon_pairs.txt`. Hashes in this folder are **TBD** until a
fit. Soft-skip ≠ PASS.

```bash
# Fails with rc=2 until CRT rbf/bin exist (expected today):
./scripts/install_paired_crt.sh
```

## Proof

- **VGA RGB 15 kHz TV CRT** is the proof.
- HDMI grabber is **not** the CRT proof (15 kHz is below the TMDS floor).
- Soak when a CRT RBF exists (Plex Web cast, do not poke `video_mode`):

```bash
# After a real 600 s cast on CRT glass — not this draft:
SOAK_LIVE=1 ./scripts/soak_crt15_unique.sh
```

Gate: `hw_presents / elapsed ≥ 23.5` and `elapsed ≥ 580`. `hw_presents=unavailable`
or a missing daemon is **rc=2**, not PASS.

## INI (VGA / SCART)

```ini
[Plex]
vga_scaler=0
composite_sync=1
```

## Do not

- Claim BUILD_OK or invent RBF md5.
- Poke ascal `video_mode` 15 kHz during play and call it CRT PASS.
- Overwrite `Plex_480p.rbf` / `Plex_720p24.rbf` / `misterplexd.480p` / `misterplexd.720p24`.
- Treat HDMI grabber black or chevron as CRT evidence.
