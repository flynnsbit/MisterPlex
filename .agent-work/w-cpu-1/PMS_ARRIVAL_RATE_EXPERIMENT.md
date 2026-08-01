# PMS supply instrument — REPLACED (Recv-Q)

## VOID (do not run)

`tools/pms_arrival_rate_sample.sh` — rchar vs NOMINAL_BPS. Parent measured blind RED
(STALL 12/12) while cast healthy. Stub now exits **rc=77**.

See parent: `RESULT_pms_supply_not_the_limiter.md`.

**Supply hypothesis RETIRED** (parent): Recv-Q never below ~482 KB during live play.

## Replacement

`tools/pms_recvq_backlog_sample.sh` + `host/libmisterplex/ss_recvq_sample.hpp`

- Score **Recv-Q** backlog (ss -tinp, pid= AND fd=)
- No NOMINAL_BPS
- Mandatory **wall_s** liveness gate per window
- Blind counter → NO-DATA rc=77, never defect

### Parent command (on device, during playing)

```sh
WINDOWS=10 WINDOW_S=2 BACKLOG_MIN=100000 \
  sh tools/pms_recvq_backlog_sample.sh
echo "true rc=$?"
```

PRE-REGISTER: `predict_verdict=NOT_SUPPLY_LIMITED` (parent already measured).
