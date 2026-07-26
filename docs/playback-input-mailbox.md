# Playback input mailbox

MiSTer `Main` grabs `/dev/input/event*`, so `misterplexd` must not read evdev or touch the HPS↔FPGA SPI bus for playback controls. The core receives keyboard/controller events through `hps_io`, edge-decodes them, and publishes commands in DDR.

## Controls

- Keyboard: `Space` = Play/Pause, `Esc` = Stop, `Right Arrow` = Skip Fwd, `Left Arrow` = Skip Back.
- Controller: `J1,Play/Pause,Stop,Skip Fwd,Skip Back;` maps to `joystick_0[4]..[7]`.

## DDR word

Address: `0x3007F108`, one 64-bit little-endian word, magic `0x504C5849` (`PLXI`).

```
[31:0]  magic
[39:32] cmd       1=PlayPause, 2=Stop, 3=SkipForward, 4=SkipBack
[47:40] cmd_seq   increments for every command, including repeated same-key presses
[63:48] seq       increments for every mailbox publish; use for torn/stale rejection
```

Read twice and accept only if both reads match, `magic == PLXI`, and `seq` or `cmd_seq` advanced since the last accepted command.
