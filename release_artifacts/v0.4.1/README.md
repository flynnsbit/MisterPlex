# MiSTerPlex v0.4.1 core

This is the hardware-validated true480 native-aspect core promoted from
`release_artifacts/good-state-true480-native-aspect-07f54d9f/`.

| Property | Value |
|---|---|
| `Plex.rbf` MD5 | `07f54d9f8f0eda2fe75d9cc314f6de54` |
| `Plex.rbf` SHA-256 | `9d4977936d1b1a3420a3e97df976058573e70a34fd0c8917f2d785a5fe0d07cf` |
| Worst setup slack | `+0.401 ns` |
| Worst hold slack | `+0.032 ns` |

The core provides one runtime content selector: production 240p and 480p,
plus an alpha 720p path. The v0.4.1 daemon supplies the original source aspect
ratio so MiSTer's scaler can apply widescreen, 4:3, or custom display policy.
