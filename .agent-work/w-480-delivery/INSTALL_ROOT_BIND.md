# Install-root conf/ffmpeg bind (w-480-delivery)

## Parent finding (device logs, retained)
- Live binary: `/media/fat/misterplex_v2/bin/misterplexd`
- Pre-fix defaults: conf + ffmpeg hardcoded under `/media/fat/misterplex/`
- Logs: `8x DECODE adopted … from …/misterplex_v2/…`, `1x … from …/misterplex/…`
- Trap: missing/unreadable v2 conf → silent v1 `DECODE=320x240` + possibly different ffmpeg

## Policy decision — foreign conf is an **error** (rc=12)
**Argue error, not warning:** a conf from a different install root pairs alien DECODE
geometry and (by default) alien ffmpeg with a binary that was never tested against
that pair. Parent already saw one silent v1 adopt. A warning still boots the
daily driver at quarter resolution — the exact class the user reported by eye.
Lab escape only: `MISTERPLEX_ALLOW_FOREIGN_CONF=1`.

Missing install conf is also **error** (rc=12). Missing install ffmpeg is **error** (rc=13).
Never probe the other root.

## Resolution order (product, after this change)

### install_root
`readlink /proc/self/exe` → if path ends with `/bin/<name>`, parent of `bin` is root.
Else dirname(exe). Fallback: argv0.

### conf
1. `--conf PATH` if given → must be R_OK; conf's directory must equal install_root
   unless `MISTERPLEX_ALLOW_FOREIGN_CONF=1`. Else FATAL rc=12.
2. Else `$install_root/misterplex.conf` if R_OK → adopt.
3. Else FATAL rc=12 — **never** `/media/fat/misterplex/misterplex.conf`.

### ffmpeg (after conf bound)
1. `--ffmpeg PATH` if given → must be X_OK or FATAL rc=13.
2. Else conf `FFMPEG=` if set (user-owned; never rewritten) → must be X_OK or FATAL.
3. Else `$install_root/bin/ffmpeg` if X_OK → adopt.
4. Else FATAL rc=13 — **never** probe `/media/fat/misterplex/bin/ffmpeg`.

## Evidence (host)

### Unit `test_install_paths` (RED baseline + GREEN)
```
./build/test_install_paths; echo "true rc=$?"
# true rc=0
# includes: legacy helper always v1; missing v2 conf fails (not adopt v1);
#           foreign --conf fails; disk trap layout fails.
```

### Binary smoke (temp roots under .agent-work)
| case | true rc | greppable |
|------|---------|-----------|
| v2 bin, no v2 conf, v1 conf present | **12** | `CONF_RESOLVE_FAIL reason=missing_install_conf`; no `320x240` |
| v2 conf + v2 ffmpeg present | **124** (timeout=running) | `CONF_RESOLVE_OK source=install_root`; `FFMPEG_RESOLVE_OK source=install_root_bin` |
| `--conf` pointing at v1 root | **12** | `reason=foreign_cli_conf` |

## Parent read-only device commands (agent does not run these)

Same-binary check for the two ffmpeg paths:
```sh
md5sum /media/fat/misterplex/bin/ffmpeg /media/fat/misterplex_v2/bin/ffmpeg
ls -l /media/fat/misterplex/bin/ffmpeg /media/fat/misterplex_v2/bin/ffmpeg
# if both exist:
cmp -l /media/fat/misterplex/bin/ffmpeg /media/fat/misterplex_v2/bin/ffmpeg | head
echo "true rc=$?"
```

Live conf/ffmpeg actually in use (after deploy of this binary):
```sh
pid=$(pidof misterplexd | awk '{print $1}')
echo "pid=$pid"
tr '\0' ' ' < /proc/$pid/cmdline; echo
readlink -f /proc/$pid/exe
# greppable lines from daemon stderr/log:
grep -E 'CONF_RESOLVE_|FFMPEG_RESOLVE_|ffmpeg_path=' /media/fat/misterplex_v2/misterplexd.log | tail -20
```

## Files
- `host/libmisterplex/install_paths.hpp` — pure policy
- `arm/misterplexd/main.cpp` — wired resolve + FATAL exits
- `tests/unit/test_install_paths.cpp` — red-before-green
