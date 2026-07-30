# Timeline stuck at 0:00 — device-side observables (no fix)

**Lane:** device-owner (observe only; `w-timeline` owns fix)  
**Daemon:** `fb9f7619` · **RBF:** `14eaeff3` · **CORENAME:** Plex  
**User cast observed:** rk=`40868`, ~91 min item, Web UI path

## 1. Split: play vs report — **PLAY WORKS**

| Observation | Evidence |
|-------------|----------|
| `state=playing`, `location=fullScreenVideo` | player `/player/timeline/poll` during session |
| Player `time` advanced | log `HTTP OUT 200 timeline` … `time="0"` → `time="1098044"` (dur `5484416`) |
| ffmpeg running on universal transcode | `ps` during session; cmdline `-i https://…plex.direct…/start.mp4` |
| PMS timeline URLs carried advancing `time=` | 59× `pms timeline: update ok` for rk=40868, times 0…~1.1e6 ms |

**Disambiguation:** this is **not** a “playback broken” failure. Media plays. Symptom matches **controller scrubber / PMS progress** not tracking the player.

## 2. Outbound `/:/timeline` — **POSTs (GETs) fire; host ≠ conf**

Daemon uses **HTTP GET** via `plexHttpGetNoBody` → `httpGet` (`curl -sS -g -k`), not POST.

| Fact | Value | Artifact |
|------|-------|----------|
| Does reporter run? | **Yes** | 59 lines `pms timeline: update ok` for 40868; **0** `update failed` in full log |
| Host for user Web cast | **`https://75-30-183-153.97f3493ee5664b189b604e11500b0a5e.plex.direct:32400`** | all 59 URLs |
| Conf `PLEX_BASE` | `http://YOUR-PLEX-SERVER:32400` | `misterplex.conf` |
| Lab API casts (earlier) | `.41` timeline URLs | 87 historical ok lines to `.41` |

**playMedia (Web)** (token redacted in log):

```text
HTTP IN GET /player/playback/playMedia?address=75-30-183-153%2E97f3493ee5664b189b604e11500b0a5e%2Eplex%2Edirect
  &machineIdentifier=1cdd1b7f718cb9f111a2a92abcdd50c7733d14fe
  &key=%2Flibrary%2Fmetadata%2F40868&protocol=https&port=32400&…
```

Session `baseUrl` follows **cast address**, not conf — correct for that request.

### HTTP status of daemon timeline calls — **NOT in the log**

`pms_timeline.cpp` logs only `ok`/`failed` from sink bool. Sink:

```cpp
// plex_resolve.cpp plexHttpGetNoBody
const std::string body = httpGet(...);
return !body.empty();
```

`httpGet` **does not check HTTP status** (no `-w %{http_code}`, no `FAILONERROR`).  
**401 Unauthorized** body is **91 bytes HTML** → **non-empty → sink true → log `update ok`.**

Measured independently (device curl):

| Request | HTTP | Body |
|---------|------|------|
| plex.direct `/:/timeline` + garbage token | **401** | 91 B HTML (non-empty) |
| plex.direct `/status/sessions` + **conf** `PLEX_TOKEN` | **401** | Unauthorized |
| `.41` `/:/timeline` + conf token (rk=12 lab) | **200** | XML `playbackState=progress` (viewOffset odd `-1` on synthetic hit) |
| plex.direct `/:/timeline` + **live session token** (during play) | **200 once** (`viewOffset` matched ~458s) and **401** on later probe | token/header sensitive |

**Therefore:** daemon log line `pms timeline: update ok` is **not proof of HTTP 2xx**.  
We have: *log says ok* (evidence). We do **not** have: *daemon’s curl exit/status was 2xx for each of the 59* (not recorded).  
False-OK on 401 is a **code fact** (`!body.empty()`), highly relevant to silent auth failure.

## 3. What the daemon believes vs `.41`

| Source | machineIdentifier | Reachability from MiSTer |
|--------|-------------------|---------------------------|
| conf `PLEX_BASE=http://YOUR-PLEX-SERVER:32400` | **`4edd44aa…175571a0`** (`/identity`) | OK when measured (also saw brief `No route to host` earlier — intermittent) |
| Live Web cast / timeline host `*.plex.direct:32400` | **`1cdd1b7f…733d14fe`** (`/identity`) | OK |
| rk=`40868` on `.41` | — | **HTTP 404** |

**Two different PMS machine IDs** (same claimed version string `1.43.3.10828-00f62d37d`).  
User library item **40868 is not on `.41`**. Web cast targeted **`1cdd1b7f` via plex.direct**, not conf node-worker1 identity.

## 4. Errors swallowed?

| Check | Result |
|-------|--------|
| `update failed` count | **0** |
| Status code in log | **absent** |
| 401 → empty body? | **No** (91 B) → counted success |

So: *log does not contain failures* ≠ *no HTTP failures*. Mechanism for silent fail is in-tree.

## 5. GDM fix `90a82208` co-suspect

| | |
|--|--|
| Timeline path active? | **Yes** (59 updates, player poll stream healthy) |
| GDM-shaped symptom (no cast / discovery)? | **No** — cast stuck, play held ~18+ min, ffmpeg on plex.direct |
| Attribution | **No evidence** this session that GDM broke timeline. **Evidence supports address/identity/token/status-blind sink** as the live shape. GDM not exonerated historically; **not implicated by these observables.** |

## 6. Player-side timeline (for Web poll path)

Web/`commandID=1` **does** long-poll the player and receives advancing `time=` (`HTTP IN …/player/timeline/poll` + `HTTP OUT 200 timeline`).  
If the user’s scrubber still shows 0:00, either UI binds to **PMS** progress (`/:/timeline` / sessions), or a controller-side bug — **not** “player time frozen.”

## Hand-off to `w-timeline` (fix not done here)

1. **Log real HTTP status** (and treat non-2xx as failed). Today `ok` is `!body.empty()`.  
2. **Reconcile dual PMS IDs:** conf `.41`=`4edd44aa` vs Web `plex.direct`=`1cdd1b7f`; ensure timeline token+client-id match the cast server.  
3. **Verify** session token used in `PmsTimelineSession` is the cast token (not only conf token) on remote-access casts.  
4. Optional: confirm whether Plex Web scrubber reads player poll vs PMS `viewOffset`.

## Device left

User session ended or idle at capture end: `location=navigation`, no ffmpeg.  
RBF `14eaeff3`, daemon `fb9f7619`, `CORENAME=Plex`, `DECODE=320x240`, `PRESENT_PROFILE=0`, bit4 clear. **No code/deploy changes.**

## S1/S2 scaler

Still deferred (priority + user was mid-play for observation window).
