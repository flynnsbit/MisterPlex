# True480 native-aspect good state

This directory preserves the exact MiSTerPlex pair deployed on 2026-08-12
after the native source-aspect and true480 integration.

## Exact pair

| Artifact | Identity |
|---|---|
| FPGA source | `8bc4d0b75b972e7bc28b24fc870b21e91b0c3306` |
| Daemon source | `ce705a81b6ad3ab974af4c4c4293e5aa0a5ef055` |
| Integrated `480p` head | `90621a126d62a1e76f48f31108b86e509e9438f7` |
| `Plex.rbf` MD5 | `07f54d9f8f0eda2fe75d9cc314f6de54` |
| `Plex.rbf` SHA-256 | `9d4977936d1b1a3420a3e97df976058573e70a34fd0c8917f2d785a5fe0d07cf` |
| `misterplexd` SHA-256 after decompression | `acfa03d762833994874b13a8aad4f734cf2f5649a3759238764917b6e3b77e7c` |
| `misterplexd.gz` SHA-256 | `5694c9a7ef2151e228911c28ca18e4224b0368e404b8edb54042558d746a25dc` |

## Hardware evidence

- Quartus critical hierarchy survived fitting.
- Worst setup slack was `+0.401 ns`; worst hold slack was `+0.032 ns`.
- Source DAR is committed through tokenized `PLXA` and exact `PLXJ`
  acknowledgement before playback.
- Grid720 published `16:9`; 4:3 Glass published `4:3`.
- The user reported the real Star Trek image looked excellent on glass.
- Local 4:3, 24 fps, AAC Glass playback held steady source cadence with
  matching PLXD presents and a flat approximately 100 ms MrAudio ring.
- The 480p PMS ladder is capped to the proven dual-A9 realtime pixel budget;
  the FPGA presentation remains 640x480.

## Open real-content confirmation

The user observed low cadence and increasing audio delay on remote Star Trek
ratingKey `40870` before the realtime decode cap was deployed. Its Plex Web
transient token was not available for an autonomous post-fix recast. Recast
that item before calling this pair fully playback-certified.

## Restore

```bash
gzip -cd \
  release_artifacts/good-state-true480-native-aspect-07f54d9f/misterplexd.gz \
  > /tmp/misterplexd
chmod +x /tmp/misterplexd

DEPLOY_LOAD=menu ./scripts/deploy_plex_core.sh \
  release_artifacts/good-state-true480-native-aspect-07f54d9f/Plex.rbf
```
