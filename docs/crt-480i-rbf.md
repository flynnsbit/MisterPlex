# 480i 15 kHz weave RBF (sibling of the true480 QSF)

The glass-good **240p/480p** pair stays `Plex.qsf` / RBF md5 `07f54d9f`.
Do not change `clk_sys` or present macros on that file (L52). 15 kHz 480i
weave is a sibling fit: `fpga/Plex_MiSTer/Plex_480i.qsf`.

ascal 15 kHz `video_mode` is **RED** (HDMI black / torn chevron). CRT needs
this fabric beam, not ascal.

**No BUILD_OK yet.** Exclusive Quartus is not this sibling (240p15 occupies
the sole fit slot). Soft-skip ≠ PASS. This doc is the copy-over recipe only.

## Why a second QSF

| | true480 product | 480i weave fork |
|--|--|--|
| clk_sys | 20 MHz | **20 MHz** (no `PLEX_CLK_SYS_24`, no new PLL) |
| Beam | 672×496 CE/2 → 30.0019 Hz | 849×262/field CE 2/3 → **15704.750687 Hz H / 59.94179652 Hz field** |
| DE | 640×480 progressive | 640×240 per field |
| Store | 640×480 I420 @ `0x30000000` / doorbell `0x300FF000` | same bank; weave `y={vc,field_odd}` |
| Prefetch | 8 lines | 8 lines |
| Macros | `PLEX_PRESENT_TRUE_480P` only | `TRUE_480P` + `PLEX_PRESENT_480I` |
| Mutually exclusive | — | `PLEX_PRESENT_240P15`, `PLEX_PRESENT_720P_L4` |

Contract: `fpga/Plex_MiSTer/rtl/plex_15k_bw_contract.svh`.
`FIRST_ODD=1`, `HALFLINE=0`, `FRAME_LINES=524`. Cadence still ticks once per
**frame** (after the even field), not per field.

## Fit (exclusive, parent only — later)

Do not start Quartus/docker while another exclusive is LIVE.

```bash
# Copy recipe over the live project file for one exclusive remote fit,
# or point the farm at Plex_480i.qsf. Never fit locally.
cp fpga/Plex_MiSTer/Plex_480i.qsf fpga/Plex_MiSTer/Plex.qsf
# then scripts/build_rbf_remote.sh
```

Restore `Plex.qsf` from git before any 480p rebuild. Product macros on
`Plex.qsf` stay TRUE_480P only (`07f54d9f` 480p@30).

## After a future BUILD_OK

One menu deploy. FBAR reconfirm. Hard residual. Then CRT analog eyes-on.
`BUILD_OK` ≠ product PASS. HDMI/ascal is not the acceptance glass.
