# PMS Recv-Q instrument (post rd-review addendum)

## VOID forever
- rchar / NOMINAL_BPS (`pms_arrival_rate_sample.sh` → rc=77)
- stall floor `0.4 × 57000 = 22800 B/s` vs real ~9851 B/s healthy arrival
- pin by `fd=5` alone (reconnect reuses fd, resets bytes_received)
- citing `app_limited` as receive-window proof (sender-path; retracted)

## Correct
- Pin TCP **4-tuple**; `bytes_received` decrease = RECONNECT (not a rate)
- Score **Recv-Q** + **backlog_depth_s = recv_q / consume_Bps**
  - `consume_Bps = (Δbr − Δrecv_q) / Δt` (no hardcoded nominal)
- Report `recv_q / rcv_ssthresh` (receive-side)
- `WINDOW_S` default **6** (≥ burst hint); short windows print ALIAS_WARN
- wall_s liveness gate mandatory

## Parent command
```sh
WINDOWS=6 WINDOW_S=6 BACKLOG_MIN=100000 \
  sh tools/pms_recvq_backlog_sample.sh
echo "true rc=$?"
```
