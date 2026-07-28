# MiSTerPlex handoff — W-ARM

> **UPDATE — successor W-ARM, commit `beb3f6d`.** The idle-logo left-edge
> artifact has been determined **RTL-side, not ARM-side**, by measurement:
> both live DDR banks match the product-rendered idle payload **byte-for-byte,
> 449280/449280 bytes each**. Section 8 below ("current measured evidence points
> first at ARM overwriting displayed bank under stuck PLXD fallback") is
> **superseded** — in `IDLE_SCREEN=logo` both banks hold identical static
> content, so an overwrite rewrites each byte with the value already there and
> cannot be visible. `3798793` remains a correct defensive fix for *playback*,
> where banks genuinely differ; it is neither the cause nor the cure of the idle
> artifact. Full analysis, raw numbers, the remaining unknowns, and the handover
> list are in **`handoffs/misterplex-w-arm-idle-edge-findings.md`**. Read that
> first; the rest of this file is still accurate history.

## 1. Identity
- Worker ID: W-ARM
- Current branch: `w-arm-idle-edge`
- Current worktree: `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-arm-idle-edge`
- Latest code commit before this handoff: `3798793 fix(arm): avoid display bank on stuck PLXD fallback`
- Earlier W-ARM branches/commits that matter:
  - `w-arm-present-gap`: `03241d0 fix(arm): bound stuck PLXD bank release fallback`
  - `w-arm-bitstream-feed`: `a9d6d73 feat(arm): tee h264 bitstream to ddr ring`

## 2. Assignment
I owned ARM-side present/DDR timing, then the ARM-to-FPGA compressed H.264 bitstream feed, then the new idle-logo left-edge artifact triage. Current active assignment at handoff is the idle-logo artifact: determine whether the reset-logo left-edge moving black/jagged lines are ARM-side or RTL-side, fix if ARM-side without touching RBF/deploy, and coordinate real HDMI capture through W-E2E.

## 3. What is DONE and PROVEN

### Present/DDR timing recovery (done on `w-arm-present-gap`)
Measured, not assumed:
- Record said present was `10.41 ms/f` and `/dev/mem` floor `7.199 ms/f`.
- I measured present `73.5 ms/f` (`n=3`) and `/dev/mem` floor `6.72 ms/f` (`n=5`). The record was wrong.
- Root cause was 50 ms PLXD/free-bank stalls caused by current RTL never setting `free_bank_mask` after first swap.
- Post-fix present was `6.32 ms/f` (`n=3`, about `±0.30 ms/f`), `0 STALL`, about `24 pfps`.
- Budget arithmetic reported to parent: decode `21.56 ms/f` + present `6.32 ms/f` = `27.88 ms/f`, giving about `12.12 ms/f` idle-device margin at 25 fps. This is not product headroom proof.

### Timeline hypothesis refuted
Measured, not assumed:
- With my present fix resident, real client endpoint still returned `state="paused" time="0"` across six polls (`08:43:22–08:43:30`).
- This killed the hypothesis that PLXD stalls alone caused the 0:00 timeline. W-CAST later fixed the state machine (`f801829`), and parent verified `state="playing"` with increasing times.

### ARM-to-FPGA H.264 bitstream feed (done on `w-arm-bitstream-feed`)
Measured/proven:
- Implemented STREAM=0 product tee: rawvideo still feeds present path while compressed H.264 Annex-B copy is written to DDR bitstream ring.
- Live PMS probe measured `bytes=2520478`, `vcl=350`, `bytes_per_vcl=7201`, feed cost about `10 us/vcl`, `full=0`, `desync=0`.
- Reference live probe from parent: `bytes=2518116`, `vcl=350` slices. My measurement was close but not identical; measurement wins.
- Static red/green gate `tests/unit/test_bitstream_feed_static.py` printed `Scope: 17`; mutating/removing `AnnexBFramer` use made it red (`rc=1`), restore green (`rc=0`).
- Targeted validation was green: static gate, bitstream ring lifecycle, rollcall, `make plexd`, `make arm-plexd`.
- Full `make unit` did not complete because resource preflight refused active local Quartus; I did not override and did not claim PASS.

### Bitstream interface agreed with W-CAST
Product contract I told W-CAST:
- Parser frontend consumes raw Annex-B bytes from `ddr_bitstream_reader.out_valid/out_byte`, not PLXN descriptors.
- ARM writes PLXN records preserving NAL boundaries internally; RTL reader strips descriptors and emits raw Annex-B byte stream.
- `out_flush` pulses on Begin/Flush/End/reset.
- EOF is End + inactive state; no EOF byte is injected.
- Seq/session/len/nal_type are transport integrity checks inside the reader.
- Backpressure is via `out_full`; ARM uses bounded retries then disables/ends/drains fd4 if persistent Full so rawvideo pipe does not block.

### Idle-logo artifact current raw device evidence (current branch)
Commands run from `/home/flynnsbit/Projects/MisterPlex/.worktrees/w-arm-idle-edge`; outputs were redirected to `build/`, never through a pipe for rc.

Resident RBF/PLXD/PLXF probe:
```bash
sshpass -p 1 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o LogLevel=ERROR root@192.168.1.183 '
  echo RBF_MD5 $(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -d" " -f1);
  for i in 1 2 3 4 5; do
    plxdlo=$(devmem 0x3007F128); plxdhi=$(devmem 0x3007F12C);
    plxflo=$(devmem 0x3007F118); plxfhi=$(devmem 0x3007F11C);
    printf "sample=%s PLXD_lo=%s PLXD_hi=%s PLXF_lo=%s PLXF_hi=%s\n" "$i" "$plxdlo" "$plxdhi" "$plxflo" "$plxfhi";
    sleep 0.2;
  done' > build/warm_idle_edge_device_plxd_plxf_probe.log 2>&1; rc=$?
```
Result rc `0`:
```text
RBF_MD5 00eebd5e685e6cc821b13bfdcff41d0b
sample=1 PLXD_lo=0x504C5844 PLXD_hi=0xEE1F000C PLXF_lo=0x504C5846 PLXF_hi=0xFFFF103B
sample=2 PLXD_lo=0x504C5844 PLXD_hi=0xEE32000C PLXF_lo=0x504C5846 PLXF_hi=0xFFFF1040
sample=3 PLXD_lo=0x504C5844 PLXD_hi=0xEE45000C PLXF_lo=0x504C5846 PLXF_hi=0xFFFF10DE
sample=4 PLXD_lo=0x504C5844 PLXD_hi=0xEE57000C PLXF_lo=0x504C5846 PLXF_hi=0xFFFF10EE
sample=5 PLXD_lo=0x504C5844 PLXD_hi=0xEE6A000C PLXF_lo=0x504C5846 PLXF_hi=0xFFFF1009
```
Decoded from PLXD high word low nibble `0xC`: `free_bank_mask=0`, `disp_bank=1`, `swap_pending=1`, while high 16 bits (`frames_done`) advance. PLXF has magic and debug `0x10`, underrun count saturated `0xFFFF`.

Daemon corroboration command:
```bash
sshpass -p 1 ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o LogLevel=ERROR root@192.168.1.183 '
  echo RBF_MD5 $(md5sum /media/fat/_Utility/Plex.rbf 2>/dev/null | cut -d" " -f1);
  tail -n 200 /media/fat/misterplex/misterplexd.log | grep -E "PLXD|STALE|STALL|DDR-PROFILE|frame-store"' > build/warm_idle_edge_device_daemon_plxd.log 2>&1; rc=$?
```
Result contained:
```text
RBF_MD5 00eebd5e685e6cc821b13bfdcff41d0b
[PLXD-PROVENANCE] ... frames_done=45324 free_mask=0 disp=1 swap=1 ...
[STALE] sendDdrFrame: PLXD free_bank_mask stayed 0 while frames_done advanced 45324→45326; using timed bank fallback until free_bank_mask is observed
...
```
Conclusion from measured evidence: this is not yet proven to be a stride mismatch. Current daemon, under a live-but-stuck PLXD mailbox, falls back to host-planned ping-pong bank. With `disp_bank=1`, that can overwrite displayed bank 1 every other successful frame. This plausibly explains moving black/jagged left-edge corruption after reset, but HDMI before/after proof is still pending W-E2E.

Current ARM fix committed:
- `3798793 fix(arm): avoid display bank on stuck PLXD fallback`
- Change: when PLXD is live but stuck (`free_bank_mask=0` and `frames_done` advances), fallback chooses `disp_bank ^ 1` rather than the caller's ping-pong planned bank. If a future RTL fix makes `free_bank_mask` nonzero, the ARM still returns to the true PLXD free-bank handshake.

Validation commands/results for current branch:
```bash
./build/test_input_mailbox > build/warm_idle_edge_input_mailbox_restored_green.log 2>&1; rc=$?
```
Result rc `0`:
```text
Scope: 1 (PLXD stuck-release fallback bank policy)
test_input_mailbox: OK
```

Red mutation performed by replacing:
```cpp
return (static_cast<int>(status.disp_bank) ^ 1) & 1;
```
with:
```cpp
return static_cast<int>(status.disp_bank) & 1;
```
Then rebuilt and ran `./build/test_input_mailbox`.
Result rc `1`:
```text
Scope: 1 (PLXD stuck-release fallback bank policy)
FAIL ... d.bank == 0
FAIL ... d.bank == 0
test_input_mailbox: 2 failure(s)
```
Restored green rc `0`.

Other validation:
```bash
python3 tests/unit/test_unit_rollcall.py > build/warm_idle_edge_rollcall.log 2>&1; rc=$?
```
rc `0`, output:
```text
UNIT_ROLLCALL_OK actual_prereqs=33 expected_prereqs=33 actual_commands=91 protected_commands=88 expected_commands=88 actual_ignored_commands=3 expected_ignored_commands=3 makefile=/home/flynnsbit/Projects/MisterPlex/.worktrees/w-arm-idle-edge/Makefile
```

```bash
make plexd > build/warm_idle_edge_make_plexd.log 2>&1; rc=$?
```
rc `0`.

```bash
make arm-plexd > build/warm_idle_edge_arm_plexd.log 2>&1; rc=$?
```
rc `0`.

```bash
make unit > build/warm_idle_edge_make_unit.log 2>&1; rc=$?
```
rc `2`; failed before unit body because resource preflight refused active local Quartus processes:
```text
Local Quartus processes detected:
    pid=327746 rss=... quartus_sh
    pid=330395 rss=... quartus_fit
PREFLIGHT REFUSED: a local Quartus fit is running ...
resource-preflight: still refused after 20 attempts; not overriding
make: *** [Makefile:44: unit] Error 3
```
No unit PASS claimed.

## 4. What is IN PROGRESS
- Current files touched by latest code commit:
  - `host/libmisterplex/input_mailbox.hpp`
  - `arm/misterplexd/fpga_spi.cpp`
  - `tests/unit/test_input_mailbox.cpp`
- Current worktree was clean before this handoff file was written/committed.
- No daemon deploy was done from `w-arm-idle-edge`. Parent's standing rule is all further ARM deploys go from `parent/integ-hour27` only.
- No RBF touched, no `load_core`, no capture device opened by W-ARM.
- Next concrete step: have parent integrate `3798793` into `parent/integ-hour27`, deploy daemon from that integration branch only, and have W-E2E capture/reset the idle-logo screen before/after. The gate must distinguish no-signal, valid-black, and valid-content and grade the left edge automatically.

## 5. What I TRIED THAT DID NOT WORK
- I did not reproduce the left-edge artifact visually myself because W-E2E owns `/dev/video0`; opening it from W-ARM would violate the capture ownership rule.
- Initial DDR bank dumps I took were invalid for idle-logo conclusions because the device was actually playing at the time. Do not use those dumps as idle evidence.
- I first probed the wrong PLXD address (`0x300FF128`) and got zeros. Correct PLXD mailbox is `0x3007F128`, from `mailbox_abi_spec.hpp` / `input_mailbox.hpp`.
- I also initially looked at `0x3007F120` as if it were PLXF; that is SDRAM diagnostic. Correct PLXF is `0x3007F118`/`0x3007F11C`.
- The parent's stride/pitch hypothesis is not proven by current evidence. Static source review shows ARM idle YUV uses coded width 624, and RTL is also built around coded width 624 with display width 618 and present_x 11. Existing invariant gates already cover several 624/640/618 stride faults. The live PLXD fallback overwrite finding is stronger current evidence, but HDMI capture is still required.
- `make unit` could not be completed because local Quartus preflight refused. I did not override and did not kill any Quartus process.

## 6. Gates I own

### `tests/unit/test_input_mailbox.cpp`
Run:
```bash
make /home/flynnsbit/Projects/MisterPlex/.worktrees/w-arm-idle-edge/build/test_input_mailbox > build/warm_idle_edge_input_mailbox_build.log 2>&1; build_rc=$?
./build/test_input_mailbox > build/warm_idle_edge_input_mailbox.log 2>&1; rc=$?
```
Current green: build rc `0`, test rc `0`.
Prints first:
```text
Scope: 1 (PLXD stuck-release fallback bank policy)
```
What it literally compares:
- Inputs: decoded PLXD `free_bank_mask`, `disp_bank`, `swap_pending`, and `frames_done` across initial/final samples plus policy state.
- Expected behavior: if PLXD reports free bits, use a free bank; if live/stuck with `free_bank_mask=0` and `frames_done` advances, use `disp_bank ^ 1`; if stuck state later observes free bits, recover to real PLXD handshake.
What it does not cover:
- It does not prove HDMI visual output, actual DDR corruption, or the RTL allocator itself.
- It does not cover absent/stale PLXD fallback timing or `/dev/mem` side effects.
Red-check:
- Mutate `displayAvoidingFallbackBank()` in `host/libmisterplex/input_mailbox.hpp` from `disp_bank ^ 1` to `disp_bank` and rerun. It fails rc `1` with two `d.bank == 0` failures.

### `tests/unit/test_bitstream_feed_static.py` (from `w-arm-bitstream-feed`)
Run from that worktree/branch:
```bash
python3 tests/unit/test_bitstream_feed_static.py
```
Current green when restored: rc `0`, prints `Scope: 17`.
Red-check:
- Mutate/remove the expected `AnnexBFramer` path in `arm/misterplexd/media_player.cpp`; gate fails rc `1`.
What it does not cover:
- Real FPGA consumption or a live hardware consumer. It proves static product tee/framing invariants only.

## 7. Interfaces agreed with other workers
- W-E2E owns HDMI capture `/dev/video0` and should be the only process opening it. W-ARM must request captures rather than grabbing directly.
- W-FIT owns all RBF/core loads/deploys. W-ARM did not touch RBF and must not use `load_core`.
- W-CAST bitstream parser consumes raw Annex-B from `ddr_bitstream_reader.out_valid/out_byte`; not PLXN. PLXN is ARM/transport-only.
- Bitstream flush/EOF: `out_flush` on Begin/Flush/End/reset; EOF is End+inactive, not a byte.
- Bitstream backpressure: RTL asserts `out_full`; ARM bounded-retries, then disables/ends/drains fd4 if persistent Full.
- PLXD bank-release: if `free_bank_mask` has bits, it is authoritative and ARM uses it. Current-silicon stuck case is `free_bank_mask=0` while `frames_done` advances; ARM fallback must not overwrite `disp_bank`.

## 8. Open risks and anything I believe is wrong
- Biggest unfinished item: no automated HDMI capture has yet proven the idle-logo artifact is fixed or even that the PLXD overwrite is the visual cause. Treat `3798793` as a plausible ARM fix with a failing/green unit gate, not a visual PASS.
- The current RBF (`00eebd5e...`) still has frame-store issues: PLXD stuck `free=0 swap=1`, PLXF `underrun_count=0xFFFF`. ARM can avoid displayed-bank overwrites, but it cannot fix RTL swap readiness or underruns.
- The fallback chooses the non-display bank according to PLXD `disp_bank`. That assumes `disp_bank` remains meaningful even when `swap_pending=1` and `free_bank_mask=0`. Device measurement shows stable `disp_bank=1`, but visual proof remains pending.
- If W-SWAP lands an RTL fix where `free_bank_mask` becomes real, ARM should automatically resume the free-bank path. Watch for `[PLXD-RECOVER]` log. If this does not happen, inspect policy state.
- Parent's stride theory may still be right in a separate defect, but current measured evidence points first at ARM overwriting displayed bank under stuck PLXD fallback.
- I could not write the handoff to `/tmp/misterplex-handoff-w-arm.md` because this runtime has a higher-priority hard ban on all `/tmp` file operations. I stored it in the repository at `handoffs/misterplex-handoff-w-arm.md` and committed/pushed it so it survives migration.
