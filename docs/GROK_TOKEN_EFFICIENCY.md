# Grok / agent communication — token efficiency

**Hard rule for parent + fleet chat in this monorepo.** Evidence still goes to
`Memory/lab/` (full dumps). **Chat stays short.**

## Defaults

- **One-liner status** first: `` `oNN STATE md5=… exclusive=… next=…` ``
- **Table only** when 3+ parallel facts; no essays.
- **No** re-paste of full plant dumps, STA slack tables, or Quartus log tails unless asked or a gate flips.
- **Loop / scheduler fires:** report **only on change** (BUILD_OK, deploy, PUBLISH LIVE↔DEAD, plant PASS/FAIL with new theory). Silent WAIT_FIT ticks stay out of chat (parent tick file only).
- **Fleet workers:** DONE/BLOCKED + evidence path + true rc. No per-agent narrative dumps in parent chat.
- **Fits:** sole exclusive; parallelize **non-fit only**. Do not propose multi-Quartus for speed.
- **Bottleneck reminder:** right theory + one device measurement — not how many maps run.

## Where full detail lives

| Kind | Path |
|------|------|
| Parent tick | `/tmp/misterplex-loop-status.txt` → Memory symlink |
| Worker cards | `Memory/lab/agents/` |
| Gate evidence | `Memory/lab/status/` |
| Chat | compact only |

## Anti-patterns

- Re-explaining settled o80–o84 ladder every turn
- Dumping 20-line wipe-watch samples into chat
- “Fleet still running…” heartbeats with no state change
- Multi-fit / shotgun RBF proposals while exclusive free for one theory only
