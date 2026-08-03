# miss #15 — xcode never fabric-eligible (w-path)

**HARD INVARIANT (parent):** Direct play may be fabric-eligible after bitstream gate.
**Any transcode ⇒ ARM fallback.** No exceptions. Decision XML `videoProfile` is untrusted.

## Parent byte measurement (authoritative for the bug)

```
TRANSCODE 1280x720 + baseline pin → profile=Main  has_b_frames=2  level 31
DIRECT PLAY rk=36                 → Constrained Baseline  has_b_frames=0
```
Decision XML had advertised CB for the Main+B stream.

## This lane's independent sample (same host PMS, MiSTerPlex client)

```
decision XML: decision=transcode videoProfile=constrained baseline 1280x720
ffprobe sample start.mp4 (true rc=0):
  profile=Constrained Baseline  has_b_frames=0  level=31  1280x720
```
So this server *can* emit CB on xcode under some conditions — but parent already
proved it can also emit Main+B while still advertising CB. **Metadata is not a
discriminator.** Delivery class (transcode vs DP) is.

## Code (hard, not heuristic)

- `gateFabricFromPmsDelivery(true, "constrained baseline")` → `refuse_transcode_delivery`
- `fabricDecodeRouteForPmsDelivery(true, perfect_baseline_bitstream)` → ARM
- NEG unit: attr-safe CB + xcode must not open fabric
- HD regime still requests 1280×720 pixels; fabric-decode class = ARM

## Still owed (ack)

- q5 mailbox write: landed (`writePlxgQ5` @ +0x828, ABI #2)
- fps_1001: draft only under freeze #4 (bit34 vacated)
