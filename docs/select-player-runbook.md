# Runbook: Select Player shows only "Cast..." (no MiSTerPlex)

**Audience:** operator / parent / user with multiple owned Plex Media Servers.  
**Scope:** Plex Web LAN "Select Player" picker. Not MiSTer hardware bring-up.  
**Last proven:** 2026-07-30 (Plex Web **4.160.0**; parent Playwright + prefs PUTs).

Related mechanism write-up (bundle citations):  
[v2-video-baseline.md — companionServer + FriendlyName](v2-video-baseline.md#cast-target-missing-in-select-player-companionserver--friendlyname-2026-07-30).

---

## 1. Symptom (what the user sees)

| Observation | Notes |
|-------------|--------|
| Plex Web **Select Player** lists only **`Cast...`** (Chromecast) | No MiSTerPlex row; **no error toast** |
| MiSTer daemon log looks normal | GDM up, HTTP `:3005`, no cast-related failure |
| Player endpoint healthy | `GET http://<mister-ip>:3005/resources` → 200, `<Player … machineIdentifier="misterplex-dev"/>` |
| The PMS that *should* cast often already lists the player | See diagnosis below |

This is easy to misread as "MiSTerPlex is broken" or "need plex.tv registration."
**Usually it is neither.**

---

## 2. One-command diagnosis

Against the PMS you intend to cast **from** (library host), with a valid token:

```bash
# Replace host + token. Do not commit real tokens.
curl -sS "http://<your-pms>:32400/clients?X-Plex-Token=${PLEX_TOKEN}"
```

**If** the XML includes MiSTerPlex, e.g.:

```xml
<MediaContainer size="1">
  <Server name="MiSTerPlex" address="…" port="3005"
          machineIdentifier="misterplex-dev" …/>
</MediaContainer>
```

**and** Select Player still shows only `Cast...`, then:

> **Diagnosis: companion-server selection, not MiSTerPlex discovery.**

Plex Web is asking a *different* owned PMS for `/clients` (one that does not
know about MiSTerPlex). The daemon and GDM path that filled *this* `/clients`
are fine.

Optional second check on a suspected wrong companion (e.g. Android/SHIELD PMS):

```bash
curl -sS "http://<other-pms>:32400/clients?X-Plex-Token=${PLEX_TOKEN}"
# Often: size="0" — Android/SHIELD PMS measured with empty clients and no GDM probes
```

---

## 3. List owned servers and compute the sort key

Plex Web does **not** poll "the server whose library you opened." It picks one
**`companionServer`**, then:

- `GET {companionServer}/clients`
- `GET {companionServer}/neighborhood/devices`

Selection (Plex Web 4.160.0 bundle
`main-8792-5e6a05fd7fbc07797f88-plex-4.160.0-75ddd7b.js`) is the first owned,
non-cloud, non-iOS server with a private connected connection, in
**ServerCollection order**. Order key:

```text
sort_key = "0" + lower(friendlyName)     # owned
         | "1" + lower(sourceTitle+friendlyName)  # shared
         | "9" + …                       # cloud
```

Blank `friendlyName` falls back to the machine hostname (lab: both local and
SHIELD became `node-worker1` → identical keys; wrong server won).

### List resources (names + connections)

```bash
curl -sS "https://plex.tv/api/v2/resources?includeHttps=1" \
  -H "Accept: application/json" \
  -H "X-Plex-Token: ${PLEX_TOKEN}" \
  | python3 - <<'PY'
import json,sys
data=json.load(sys.stdin)
# resources may be a list or under MediaContainer depending on Accept/version
items = data if isinstance(data, list) else data.get("MediaContainer", data)
if isinstance(items, dict):
    items = items.get("Device") or items.get("resources") or []
rows=[]
for r in items:
    if not isinstance(r, dict):
        continue
    provides = r.get("provides") or r.get("product") or ""
    # servers only
    prov = r.get("provides") or ""
    if "server" not in str(prov) and r.get("product") != "Plex Media Server":
        # still print anything that looks like a server resource
        if "server" not in str(r.get("provides","")):
            pass
    name = r.get("name") or r.get("friendlyName") or ""
    owned = r.get("owned")
    platform = r.get("platform")
    cid = r.get("clientIdentifier") or ""
    # sort key mirrors Web comparator for owned non-cloud
    is_cloud = bool(r.get("isCloud") or r.get("provides") == "sync-target")
    is_shared = (owned is False) or bool(r.get("sourceTitle"))
    fn = (name or "").lower()
    if is_cloud:
        key = "9" + fn
    elif is_shared:
        key = "1" + (str(r.get("sourceTitle") or "") + name).lower()
    else:
        key = "0" + fn
    rows.append((key, name, owned, platform, cid[:16], prov))
for key,name,owned,platform,cid,prov in sorted(rows, key=lambda x: x[0]):
    print(f"{key:40}  name={name!r:30} owned={owned} platform={platform} id={cid}… provides={prov}")
PY
```

**The owned server with the smallest `0…` key that is private+connected wins
`companionServer`.** If that winner’s `/clients` is empty, the picker shows only
`Cast...`.

---

## 4. Remedy

### Required: distinct FriendlyName, intended PMS first

1. Give **every** owned PMS a **unique** FriendlyName (Settings → General, or API).
2. Make the PMS that discovers MiSTerPlex (desktop/docker host that runs GDM)
   sort **first** among owned private servers (lowest `0` + lowercased name).

```bash
# On the PMS that should feed Select Player (example name used in lab):
curl -sS -o /dev/null -w "http %{http_code}\n" -X PUT \
  "http://<your-pms>:32400/:/prefs?FriendlyName=MiSTerPlex%20Studio&X-Plex-Token=${PLEX_TOKEN}"
# Expect: http 200
```

Lab result after rename: sort keys  
`0misterplex studio` < `0node-worker1` (SHIELD) < `0studio` → Web polled the
local PMS; picker showed `Cast... | MiSTerPlex | MiSTerPlex`. SHIELD left running.

### Recommended (docker / multi-homed host): PreferredNetworkInterface

Not a companion-server pin — it only controls **what this PMS advertises**.
Still useful so plex.tv/resources does not list unreachable Docker bridges first.

```bash
# Example: Wi-Fi iface that holds the LAN IP clients use
curl -sS -o /dev/null -w "http %{http_code}\n" -X PUT \
  "http://<your-pms>:32400/:/prefs?PreferredNetworkInterface=wlp89s0&X-Plex-Token=${PLEX_TOKEN}"
# Expect: http 200
```

Official docs cover this as network advertisement only  
([Network](https://support.plex.tv/articles/200430283-network/) —
Preferred network interface / Custom server access URLs).  
They do **not** choose which server is `companionServer`.

---

## 5. WARNING — fragile, undocumented, only lever

> **There is no supported Plex setting to pin or prefer the companion server.**
>
> - [Choose a Player](https://support.plex.tv/articles/201358253-choose-a-player/)
>   describes using the picker only — no server-priority configuration.
> - [Network](https://support.plex.tv/articles/200430283-network/) documents
>   Preferred network interface and Custom server access URLs — what a PMS
>   **advertises**, not which PMS Web selects as `companionServer`.
>
> **Alphabetical `friendlyName` ordering (owned first) is the only lever
> available** (as of Plex Web 4.160.0 reverse-engineering).
>
> **Booby trap:** if anyone later **adds or renames** an owned server whose
> lowercased FriendlyName sorts **before** your cast-from name (e.g. before
> `misterplex studio`), Select Player can go back to **only `Cast...` with no
> error** and a healthy MiSTer log. Re-run §2–§3 and rename again so the
> intended PMS sorts first.

Treat FriendlyName as **load-bearing cast configuration**, not cosmetic.

---

## 6. Do not rebuild plex.tv player registration for this

| Experiment | Result |
|------------|--------|
| plex-mpv-shim (no plex.tv login) | Appears via GDM → PMS `/clients` when Web asks that PMS |
| Parent registered a plex.tv device with `provides=player` | **Picker still did not show MiSTerPlex** |
| Daemon `PLEXTV_ANNOUNCE` GET `api/v2/resources` | List only; `self_in_body=0` → `registration no-op` (`2f81e96b`) |

**plex.tv `provides=player` is neither necessary nor sufficient** for Select
Player. Do not open a lane to invent a plex.tv upsert for "no cast option."

---

## Quick recovery card

```text
1. curl …/clients on intended PMS → size≥1 with MiSTerPlex?
   NO  → fix GDM/firewall/player (see v2-video-baseline firewall section)
   YES → companionServer problem (continue)
2. List owned server names / sort keys (§3)
3. PUT FriendlyName on intended PMS so its key is first among owned (§4)
4. Hard-refresh Plex Web; open Select Player again
5. If still empty: browser net log — which host gets /clients?
   (context-level capture; page.on can miss it)
```

---

## Lab prefs actually applied (parent, both HTTP 200)

| Pref | Value | Purpose |
|------|--------|---------|
| `FriendlyName` | `MiSTerPlex Studio` | Sort key `0misterplex studio` ahead of SHIELD `0node-worker1` |
| `PreferredNetworkInterface` | `wlp89s0` | Advertise single LAN `plex.direct` connection (drop docker0/br unreachable IPs) |

Verified twice with Playwright after interface change: picker
`Cast... | MiSTerPlex | MiSTerPlex`, discovery to
`http://127.0.0.1:32400/clients` + `/neighborhood/devices`,
`POLLED_122_SHIELD: false`.
