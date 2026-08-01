# `make build/<name>` silent no-op (parent 2026-08-01)

## Defect
Makefile targets are `$(ROOT)/build/foo` (absolute via `ROOT := $(abspath ...)`).
Make matches targets by **literal string**, so:

```text
$ make build/test_ffmpeg_vf
make: Nothing to be done for 'build/test_ffmpeg_vf'.   # rc=0
$ ./build/test_ffmpeg_vf
PASS …   # STALE binary — source may have changed
```

Red-before-green on a stale binary always "passes" and proves nothing.

## Fix
Pattern rule at end of Makefile:

```make
build/%: $(ROOT)/build/%
	@true
```

Relative form depends on absolute target → rebuilds when sources change.
Unknown `build/nope` → loud `No rule to make target '$(ROOT)/build/nope'`.

## Void evidence
Any gate log that used `make build/<name>` **before** this fix and assumed a
rebuild is **VOID**. Re-run with relative form (now works) or:

```bash
make "$(pwd)/build/<name>"
```

Repo grep (`docs/`, `tests/`, `.agent-work/`): no durable RED/GREEN claims found
that cited relative `make build/` as the rebuild step. Parent's local five rc=0
runs are the known void set — re-run those binaries after this lands.

## Prove
```bash
bash tests/unit/test_make_relative_build.sh; echo "true rc=$?"
# relative_stale_mut true rc=2  (#error forces rebuild fail)
# relative_restore true rc=0
```
