# Gate coverage rule

**Fleet rule:** publish no gate result without its coverage.

`rc=0` over an empty inspection set is **UNSCORED (77)**, never PASS.
A gate that returns 0 while not looking is **worse than no gate** — it
manufactures confidence.

## API

```bash
source scripts/lib/gate_coverage.inc.sh
gate_coverage_begin "deploy-live-verify"
gate_coverage_note "live_md5" "/proc/PID/exe"
gate_coverage_note "http" ":3005/resources"
gate_coverage_finish "$wrapped_rc"   # 0+empty → 77
```

## Mutation proof

`tests/unit/test_deploy_restore_mutations.sh` injects zero notes + wrapped 0 and
asserts **true rc=77**.
