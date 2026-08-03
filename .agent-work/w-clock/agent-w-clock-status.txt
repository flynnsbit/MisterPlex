# w-clock STATUS

## Branch
`w-clock-bump` @ worktree MisterPlex-wt-clock  
**Pin main:** detached `3fa01a9b`

## PARKED
- PLL native-720p kit + CDC 4:15 (glass already 720p via ascal; target = content 1280)
- No Quartus fit (parent exclusive)

## Fmax / residual_csum (current)

| Item | Status | Evidence |
|------|--------|----------|
| Task1 present L2 Fmax risk | **MEDIUM** default-off / **HIGH** L4 enable | `FMAX_PRESENT_NETLIST_RISK.md` — no shared cone with residual_csum; placement unknown |
| Prior Fmax 32.59 | MEASURED prior netlist only | `r_tc→residual_csum` data delay 30.062 ns |
| Task2 residual_csum fix | **APPLIED default-ON** | ST_PLACE `residual_csum<=csum_acc` (zeros free under XOR) |
| PRE-REGISTER Fmax Δ | **unknown until fit** | named path eliminated; next owner unknown |
| Equiv gate | PASS | `test_residual_csum_acc_equiv.sh` true rc=0 (math+POS 0x14 + XOR1 RED + ONE_CYCLE_DELAY RED) |

## Content 1280 BEAM
Default-OFF max tier; FRAME_1280 QSF commented; enable **BLOCKED** on w-mem stride.

## Still open
- B20 PLXG atomic (NBA lag fix landed; live content_* OPEN) — B20_CLOSED=false
- PLXG reset liveness OPEN
- Product Fmax on main@3fa01a9b + this fix: **unknown — parent fit STA checklist in FMAX doc**

## Do not
Quartus fit, device, unpark PLL without grant, weaken residual golden.
