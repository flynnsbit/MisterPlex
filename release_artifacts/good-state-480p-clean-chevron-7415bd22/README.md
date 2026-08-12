# 480p clean-chevron good state

This directory preserves the exact MiSTerPlex pair running on the MiSTer when
the `480p` branch was created on 2026-08-12.

## Exact pair

| Artifact | Identity |
|---|---|
| FPGA source | `7415bd2299ed31680bb47297046d9dbba04abea5` |
| `Plex.rbf` MD5 | `3b3f3fab282d4014fb2612ef9b7cf874` |
| `Plex.rbf` SHA-256 | `0d60a867f15bd925b0ad862b03d4265c2ebca3f7f09b5db8bc1802aefcc75bb9` |
| `misterplexd` MD5 after decompression | `849fa72cb001af8afd5007710ed897ab` |
| `misterplexd` SHA-256 after decompression | `aa7e5a6b2554f68a6f7ff8aa7a5943a247e819184172d00e589e2fa09b2a8677` |
| `misterplexd.gz` SHA-256 | `7ab29d163036d9c64586049ad872212beae6e3fb14767cf8de36907e2fec06cc` |

The branch also contains the subsequent source-only fixes at `fa08111d` for
doorbell-relative mailboxes, one-shot stale-token recovery, and true480
frame-wrap prefetch. Those fixes require a newly fitted RBF; they are not
represented by the archived `Plex.rbf`.

## Proven good behavior

- Native 640x480 HDMI presentation.
- PMS coding profile 624x480 with 618 visible pixels and 11-pixel pillars.
- Clean two-color Plex orange chevron confirmed on HDMI glass by the user.
- Quartus timing passed: worst setup `+0.404 ns`, worst hold `+0.192 ns`,
  with no negative TNS.
- The matched daemon and API remained stable.

Configuration used:

```ini
DECODE=640x480
TRANSCODE_PROFILE=480p
PRESENT=fpga
IDLE_SCREEN=logo
STREAM=0
WEAK_BITRATE=2500
AUDIO=on
OSD_CONTROL=1
```

The live OSD word was `0x8010` (480p content and 480p display).

## Known limitations

This is intentionally archived as a **good state**, not a fully certified
release:

- The chevron and idle spatial output pass.
- The RBF writes PLXF/PLXD to legacy addresses `0x3007F118/0x3007F128`
  instead of the true480-relative addresses `0x300FF118/0x300FF128`.
- Its unchanged-token fallback repeats, so idle `frames_done` advanced from
  5442 to 5502 in two seconds and `swap_pending` stayed asserted.
- Plex can advertise MiSTerPlex as a cast target, but playback can do nothing.
- Playback, controls, cadence, audio, and A/V sync are therefore not certified.

## Restore

Verify the archived pair:

```bash
md5sum release_artifacts/good-state-480p-clean-chevron-7415bd22/Plex.rbf
gzip -cd release_artifacts/good-state-480p-clean-chevron-7415bd22/misterplexd.gz \
  | md5sum
```

Restore the daemon binary before deploying:

```bash
gzip -cd release_artifacts/good-state-480p-clean-chevron-7415bd22/misterplexd.gz \
  > /tmp/misterplexd
chmod +x /tmp/misterplexd
```

Use the repository safe-deploy procedure for the RBF, with one Menu bounce:

```bash
DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh \
  release_artifacts/good-state-480p-clean-chevron-7415bd22/Plex.rbf
```

Do not describe this pair as playback-certified; its purpose is to retain the
known clean 480p HDMI/chevron baseline.
