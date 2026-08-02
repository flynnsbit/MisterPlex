# PARENT CARD — locus480 v2 (saturated discriminator MISS + fix)

Branch: `w-instr-provenance`  
Tool: `tools/locus480_local_vs_supply.py`

## MISS (published — your hardware)

v1 pre-register:
| LOCAL | recv_q>0 sustained | any ffmpeg `pipe_write` |
| SUPPLY | recv_q~0 | not pipe_write |

Your healthy run (supply=0.993 drops=16 n_rows=300):
```
recv_q_gt0_frac=1.0  recv_q_max=83549
ffmpeg_pipe_write_frac=1.0
```
**Both LOCAL indicators at ceiling while nothing is wrong.**

Cause **by design**: audio pacer back-pressures ffmpeg at 1× (`media_player.cpp`
audioPump / present loop). Normal paced playback holds a non-empty socket and
threads in `pipe_write`. Binary LOCAL cannot rise in degradation — w-lint
shape (a) saturated gate.

**Had you scored a degraded run with v1, it would have printed LOCAL rc=3
unconditionally.** Tool now makes that impossible.

## FINDING THAT STANDS
`recv_q>0` with tens of KB unread throughout a healthy run → **socket never
empty under intentional pacing** → steady-state link/sender-short refuted.
Emitted as `finding_socket_never_empty_healthy=1`.

## v2 PRE-REGISTER (within-run healthy baseline)

Split each run into non-degraded vs degraded seconds (same soak).

| | recv_q magnitude / d_recv_q | pipe_write **thread** frac |
|---|---|---|
| **LOCAL** | median_deg/median_h ≥ 2.0 **or** mean d_recv_q_deg > healthy | delta ≥ +0.10 (if not saturated) |
| **SUPPLY** | median_deg/median_h ≤ 0.5 (collapse) | delta falling / not rising |

Thresholds labelled `DEFAULT_ASSUMED`; overridable via CLI.

## SATURATION GUARD (general)
If an indicator is at ceiling (≥0.95) or floor (≤0.05) on the **non-degraded**
portion of the **same** run → mark `SATURATED_*` and **do not use** for verdict.
Binary recv_q>0 and binary any-pipe_write are expected SATURATED under pacing —
printed for provenance, never as locus proof.
If no unsaturated discriminative channel remains → `INSUFFICIENT_EVIDENCE rc=78`.

## residual=1
Never rounded. On closable ledger: `residual=1 residual_class=near_closed_abs_le_1`
with explicit NOTE. On your 7072-frame run that is consistent with a true
off-by-one or 1-frame pairing skew — still reported as 1, not coerced to 0.
Atomic 1 Hz `frameLedgerTelemetryFragment` removes pairing ambiguity.

## Commands (unchanged shape)

```sh
# device
python3 tools/locus480_local_vs_supply.py sample \
  --out /media/fat/misterplex_v2/locus480.jsonl --interval 1 --duration 300
echo "true rc=$?"

# host
python3 tools/locus480_local_vs_supply.py self-test
echo "true rc=$?"   # expect 0

python3 tools/locus480_local_vs_supply.py verdict --in ./locus480.jsonl
echo "true rc=$?"
```

## RBG true rc (this lane)

| case | VERDICT | rc |
|------|---------|-----|
| self-test | SELF_TEST_OK | **0** |
| paced healthy (v1 would say LOCAL) | INSUFFICIENT_EVIDENCE + SATURATED + finding | **78** |
| LOCAL magnitude climb | LOCAL_ESTABLISHED ratio≈3.57 | **3** |
| SUPPLY backlog collapse | SUPPLY_ESTABLISHED ratio≈0.05 | **2** |
| flat backlog trap (binary LOCAL) | LOCUS_UNKNOWN | **4** |
| residual=1 fixture | residual=1 near_closed | not rounded |

Logs: `.agent-work/w-instr/locus_rbg_v2/`

Rule 0: no device touched by agent. You re-run soaks when ready.
