# W-AUDIT mailbox regression attack — fb4bad84

Branch under audit: `parent/integ-hour27` at `8b7b45b` (same relevant RTL/ABI as the W-FIT `6818ecf` sampler commit).

## Raw measurements

W-FIT legacy-page logs:

| artifact | RBF | address sampled | samples | raw distinct | frames | delta | free nonzero | swap zero | disp transitions |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `.copilot-logs/wfit2-telemetry-PREDEPLOY-00eebd5e.log` | `00eebd5e` | `0x3007F12C` | 40 | 40 | `18925→19606` | `681` | `0/40` | `0/40` | `0/39` |
| `.copilot-logs/wfit2-telemetry-POSTDEPLOY-fb4bad84-idle.log` | `fb4bad84` | `0x3007F12C` | 40 | 1 | `41094→41094` | `0` | `0/40` | `0/40` | `0/39` |

Static product-source facts on `parent/integ-hour27` `8b7b45b`:

```
present_core.sv passes .DOORBELL_PHYS(DDR_FRAME_YUV420P_DOORBELL_PHYS)
DDR_FRAME_YUV420P_DOORBELL_PHYS = 0x300FF000
therefore fitted ddr_frame_store PLXS = 0x300FF100 and PLXD = 0x300FF128

host/mailbox_abi_spec.hpp fixed PLXS = 0x3007F100 and PLXD = 0x3007F128
address delta = +0x00080000 for both PLXS and PLXD
```

Read-only live probe, no sentinel writes, no reload, no `/dev/video0`, after W-FIT
left the device on `fb4bad849ad2db782a5004ce5a3471ce`:

```
md5=fb4bad849ad2db782a5004ce5a3471ce
core=Plex
0x3007F100=0x00000000
0x3007F104=0x00000000
0x3007F128=0x00000000
0x3007F12C=0x00000000
0x300FF100=0x504C5853
0x300FF104=0x3DC44000
0x300FF128=0x504C5844
0x300FF12C=0x165C0002
after_1s
0x3007F100=0x00000000
0x3007F104=0x00000000
0x3007F128=0x00000000
0x3007F12C=0x00000000
0x300FF100=0x504C5853
0x300FF104=0x3F524000
0x300FF128=0x504C5844
0x300FF12C=0x16A20002
ssh_rc=0
```

Read-only 40-sample correct-page PLXD probe at `0x300FF12C`, 0.25 s interval:

```
resident md5 fb4bad849ad2db782a5004ce5a3471ce, CORENAME=Plex
samples=40
frames_done 7152→7826, delta=674
free_bank_mask_nonzero=28/40
swap_pending_zero=28/40
disp_bank_transitions=0/39
raw values alternated between ...0002 and ...0008 forms while frames advanced.
```


Additional false-green gate evidence on the same branch:

```
python3 tests/unit/test_rtl_invariants.py  rc=0
PASS DDR mailbox host/RTL ABI constants (single-source-of-truth spec gate)
PASS DDR bank handoff publishes fenced frames and guards same-bank reuse (PLXD bank-release ACK at 0x3007F128)
```

That gate passed while the fitted `DDR_FRAME_STORE` mailbox writer is parameterized
for `0x300FF128`, so the current ABI invariant is not checking the elaborated
product address.

## Interpretation

**BROKE W-FIT claim (b) as stated.** The deployed `fb4bad84` fabric is not silent
on PLXS/PLXD. It is publishing live PLXS and PLXD at `0x300FF100/0x300FF128`;
W-FIT's dead-mailbox probe attacked the legacy fixed page
`0x3007F100/0x3007F128`.

**BROKE W-FIT claim (c) for the raw telemetry observables.** The binding
observables are measurable at the fitted RTL address:

- `free_bank_mask != 0`: `28/40`.
- `swap_pending == 0`: `28/40`.
- `frames_done` advanced by `674` in about 10 s.

`disp_bank` did not toggle in that 40-sample window (`0/39` transitions), so this
is not a picture-success claim and not a full frame-store pass. It does, however,
invalidate "PLXD/PLXS are dead instruments" for `fb4bad84`.

**W-FIT claim (a) remains true but is now about the old legacy page.** The old
`00eebd5e` build genuinely produced a live-looking `0x3007F12C` counter at about
vsync rate (`681/10 s`) with `free=0 swap=1 disp=1`.

## Root cause of the false red

This is another "true number about the wrong thing":

- W-FIT correctly proved the legacy page `0x3007F1xx` was dead after it zeroed it.
- The product RTL being fitted is parameterized for the YUV doorbell page
  `0x300FF000`, so its mailboxes are at `0x300FF1xx`.
- The ARM ABI, several hardware gates, and W-FIT's sampler still use
  `0x3007F1xx`.

The immediate owner-facing defect is an address-contract split between the ARM
mailbox ABI/gates and the current DDR_FRAME_STORE RTL. I am not patching it here;
W-AUDIT is reporting the evidence.

## Reproduction

Static:

```
cd /home/flynnsbit/Projects/MisterPlex/.worktrees/w-audit
python3 scripts/w_audit_mailbox_regression_audit.py
```

Optional live read-only check:

```
python3 scripts/w_audit_mailbox_regression_audit.py --live-read
```

No Quartus, deploy, load_core, sentinel write, or video capture is used.
