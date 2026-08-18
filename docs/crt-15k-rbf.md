# CRT 15 kHz RBF (fork of the v0.4.1 true480 QSF)

The glass-good **240p/480p** pair stays `Plex.qsf` / RBF md5 `07f54d9f`.
Do not change `clk_sys` on that file. A **15 kHz CRT** present path
(240p15 / 480i) needs a sibling fit: `fpga/Plex_MiSTer/Plex_15k.qsf`.

## Why a second QSF

| | true480 product | 15 kHz fork |
|--|--|--|
| clk_sys | 20 MHz | **20 MHz** (do not raise; L52) |
| Beam | 672×496 CE/2 → 30.0019 Hz progressive | `PLEX_PRESENT_15K` (w-fpga `present_beam_15k`) |
| Store | 624/618/640 @ 8-line prefetch | **same** (`DDR_FRAME_STORE` `FRAME_W=640` `FRAME_H=480` `FRAME_LINES_8`) |
| Macro | `PLEX_PRESENT_TRUE_480P` | `PLEX_PRESENT_15K` (TRUE_480P **off**) |
| 240/480 HDMI glass | production | **not this RBF** |

true480 already clocks ~14.88 kHz H at CE/2, but it is **progressive 480 @ 30 Hz**.
A 15 kHz CRT wants 240p or 480i, not that 30p raster. Hence a fork, not a
toggle on the shipping file.

`rtl/present_beam_15k.sv` is listed in `files.qip` **commented** until the
fpga worker lands the file. Parent uncomments before the exclusive fit
(L10: omitted file is invisible; missing path fails every QSF that sources
`files.qip`, including live `Plex.qsf`).

## Fit (exclusive, parent only)

```bash
# Copy recipe over the live project file for one exclusive remote fit,
# or point the farm at Plex_15k.qsf. Never fit locally.
cp fpga/Plex_MiSTer/Plex_15k.qsf fpga/Plex_MiSTer/Plex.qsf
# then scripts/build_rbf_remote.sh
```

Restore `Plex.qsf` from git before any 480p rebuild.

```bash
git checkout -- fpga/Plex_MiSTer/Plex.qsf
```

Do not leave `Plex_15k.qsf` copied over `Plex.qsf`. The next 480p fit
would bake `PLEX_PRESENT_15K` into the product recipe.

## Sibling QSF names

Locked L52 pair (parent-only exclusive; next exclusive after 240p15
BUILD_OK+soak is 480i):

| File | Role |
|--|--|
| `Plex_240p15.qsf` | locked 240p15 sibling (LIVE exclusive first) |
| `Plex_480i.qsf` | locked 480i sibling (after 240p15 BUILD_OK+soak) |
| `Plex_15k.qsf` | **older name** (`PLEX_PRESENT_15K`). Kept. Do not delete. |

`Plex_15k.qsf` predates the locked names and stays in this tree. It is
not `Plex_240p15.qsf` / `Plex_480i.qsf`. Parent lands those recipes
separately; this file is the older 15 kHz fork only.

## Isolated slot prep (parent-only exclusive)

Never overwrite shipping `Plex.qsf` in the product tree during a live
compile (L52: `cp Sibling.qsf Plex.qsf` only inside an isolated slot).
Do not write `/home/flynnsbit/mplex-builds/crt240p15` (LIVE 240p15).

```bash
# dry-run is the default (prints the plan, copies nothing)
scripts/prep_sibling_fit_slot.sh Plex_240p15.qsf
scripts/prep_sibling_fit_slot.sh Plex_480i.qsf

# parent, after exclusive is FREE:
scripts/prep_sibling_fit_slot.sh --apply Plex_240p15.qsf
scripts/prep_sibling_fit_slot.sh --apply Plex_480i.qsf
```

Default SLOT is `/home/flynnsbit/mplex-builds/<stem>` (`Plex_240p15`,
`Plex_480i`). The script refuses if `/tmp/misterplex-exclusive.lock`
exists, docker `mplex-fit-*` is Up, or SLOT is the live `crt240p15`
path. Exit 3 if the sibling QSF is missing. FIT=NO — this is copy-over
prep, not a Quartus launch.

## After BUILD_OK

One menu deploy. Soft-skip ≠ PASS. HDMI / ascal 15 kHz is **not** CRT
PASS (`docs/crt-lcd-lab-checklist.md`). Product gate is physical CRT
240p15 + 480i (parent: 10 min unique ≥ 23.5). No CRT attached → CRT
column stays PENDING.
