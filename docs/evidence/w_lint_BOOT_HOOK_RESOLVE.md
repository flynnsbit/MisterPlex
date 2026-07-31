# Boot hook resolve + fail-loud (w-lint)

**Land target branch:** `w-lint-gate-integrity`
**SHA:** `8b6a5e63`

## Blockers fixed

1. **main `deploy_misterplexd.sh`** wrote `HOOK=/media/fat/linux/_user-startup.sh` (DECOY) + v1 root.
   Worktree deploy resolves `USER_SCRIPT=` from `/etc/init.d/S99user` and writes that LIVE path only.
   Idempotence greps both v1 and v2 + supervise.

2. **Promotion gate** must not audit the decoy. It resolves LIVE path via
   `boot_hook_resolve_from_s99_body` then cats that path. Bundle match:
   `boot_hook_assert_bundle_match(hook_body, live_root)` fails when hook starts
   a different root than the running daemon.

## Shared API (`scripts/boot_hook_policy.sh`)

| Function | Role |
|----------|------|
| `boot_hook_parse_user_script_from_s99_body` | parse `USER_SCRIPT=` |
| `boot_hook_resolve_from_s99_body/file` | set LIVE + DECOY paths |
| `boot_hook_decoy_path_for_live` | sibling `_` + basename |
| `boot_hook_root_from_body` | install root in hook |
| `boot_hook_assert_bundle_match` | hook root == live root |
| `boot_hook_check_live_and_decoy` | LIVE must pass; decoy-only → `decoy_ok_live_bad` |

Consumers: `deploy_misterplexd.sh`, `promotion_gate_check.sh`, `rollback_v2.sh`.

## Fail-loud stale v1 daemon

```bash
scripts/quarantine_stale_daemon_tree.sh plan
QUARANTINE_EXECUTE=1 scripts/quarantine_stale_daemon_tree.sh apply   # parent only
```

Renames `/media/fat/misterplex/bin/misterplexd` → `*.QUARANTINE.54f1d916.<utc>` when md5 prefix matches.
Wrong hook then fails ENOENT instead of silently booting pre-PLXD.

## Daemon self-verify

`arm/misterplexd/main.cpp` `verifyBootHookSelf(confPath)`:
- read S99user → USER_SCRIPT
- refuse underscore decoy basename
- confirm LIVE hook contains `liveRoot/bin/misterplexd_supervise.sh`
- on mismatch: loud log + write `$liveRoot/BOOT_HOOK_MISMATCH`
- does not abort process (device stays reachable)

## Identity-not-pose

`pair_visual_gate.sh` must not use logo centroid position as pass/fail (screensaver bounces).
Static guard flags `0.25 <= orange_cy <= 0.80` if reintroduced.
