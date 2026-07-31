# Validated pair pins (auto-tracked)

Do **not** hand-edit `scripts/video_regression.sh` daemon pins for every deploy.

## Files

| Path | Role |
|------|------|
| `CURRENT` | Last parent-validated (core_md5, daemon_md5) pair |
| `ACCEPTED_DAEMONS` | One md5 (full or prefix8) per line — rollback-accepted set |

## Update after a validated deploy (parent)

```bash
scripts/pair_pin_update.sh \
  --core-md5 c5382bee73cecdee8220b811e529c297 \
  --daemon-md5 <full 32 from readlink -f /proc/PID/exe> \
  --note "w-geom breadcrumb 865d4c8a"
```

Gates resolve CURRENT first, then ACCEPTED_DAEMONS, then built-in history.
Never weaken a gate to pass a new pin — update the claim.
