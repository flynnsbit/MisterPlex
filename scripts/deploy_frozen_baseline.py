#!/usr/bin/env python3
"""Explicit, hash-pinned presentation rollback; never builds a new daemon/core."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
RBF = ROOT / "release_artifacts/v0.9.0-pre-paired/cores/Plex_480p.rbf"
DAEMON = ROOT / "release_artifacts/v0.9.0-pre-paired/bin/misterplexd.480p"
RBF_MD5 = "07f54d9f8f0eda2fe75d9cc314f6de54"
DAEMON_MD5 = "5f1c861486844f4c83bf32a2112cfbb6"
REMOTE_RBF = "/media/fat/_Utility/Plex_480p.rbf"
ENV = os.environ.copy()
ENV["SSHPASS"] = os.environ.get("MISTER_PASS", "1")
SSH = ["sshpass", "-e", "ssh", "-o", "StrictHostKeyChecking=no",
       "-o", "ConnectTimeout=6", "-o", "ServerAliveInterval=3",
       f"{os.environ.get('MISTER_USER', 'root')}@{os.environ.get('MISTER_HOST', '192.168.1.183')}"]


def remote(script, timeout=30):
    result = subprocess.run(SSH + ["bash", "-s"], input=script.encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=ENV, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"remote operation failed ({result.returncode})")
    return result.stdout.decode()


def main_argv():
    return remote("""for p in $(pidof MiSTer); do
      tr '\\000' '\\n' < "/proc/$p/cmdline"
    done""")


def wait_main(expected):
    for _ in range(20):
        lines = main_argv().splitlines()
        if expected in lines:
            return
        time.sleep(1)
    raise RuntimeError("Main did not report the requested named core; no automatic recovery")


def verify():
    for path, digest in [(RBF, RBF_MD5), (DAEMON, DAEMON_MD5)]:
        if hashlib.md5(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError("local frozen pair hash mismatch")
    for digest in (RBF_MD5, hashlib.sha256(RBF.read_bytes()).hexdigest()):
        subprocess.run(["bash", str(ROOT / "tests/unit/test_phase1a_rbf_ban.sh"), digest],
                       check=True, cwd=ROOT)
    sums = remote(f"md5sum {REMOTE_RBF} /media/fat/misterplex/bin/misterplexd.480p")
    if not sums.splitlines()[0].startswith(RBF_MD5 + " ") or not sums.splitlines()[1].startswith(DAEMON_MD5 + " "):
        raise RuntimeError("on-card named pair differs; refuse replacing it")


def core():
    lines = main_argv().splitlines()
    if lines not in (["/media/fat/MiSTer"],
                     ["/media/fat/MiSTer", "/media/fat/menu.rbf"],
                     ["/media/fat/MiSTer", REMOTE_RBF]):
        raise RuntimeError("expected confirmed Main Menu; refuse replacing another active core")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    print(remote(f"""
set -eu
cd /media/fat/misterplex
backup="backups/p0-frozen480p-{stamp}"
mkdir -p backups
mkdir "$backup"
for f in misterplex.conf; do
  [ ! -f "$f" ] || cp -p "$f" "$backup/"
done
for f in bin/misterplexd bin/misterplexd.prev-c2; do
  [ ! -f "$f" ] || cp -p "$f" "$backup/$(basename "$f")"
done
for f in /media/fat/_Utility/Plex.rbf /media/fat/linux/_user-startup.sh; do
  [ ! -f "$f" ] || cp -p "$f" "$backup/$(basename "$f")"
done
if pidof misterplexd >/dev/null 2>&1; then
  echo "Existing daemon: refuse this Menu-only rollback" >&2
  exit 3
fi
for f in /proc/[0-9]*/comm; do
  [ -r "$f" ] || continue
  IFS= read -r comm < "$f" || continue
  case "$comm" in sh|bash|misterplex*)
    p=${{f#/proc/}}; p=${{p%/comm}}
    args=$(tr '\\000' '\\n' < "/proc/$p/cmdline" 2>/dev/null || true)
    case "$args" in
      */misterplex_core_watch.sh*|*/misterplexd_supervise.sh*)
        kill -TERM "$p"
        for i in 1 2 3 4 5 6; do
          kill -0 "$p" 2>/dev/null || break
          sleep 0.5
        done
        if kill -0 "$p" 2>/dev/null; then exit 4; fi
        ;;
    esac
    ;;
  esac
done
cp -p bin/misterplexd.480p bin/misterplexd
chmod 755 bin/misterplexd
sed -i '/^[[:space:]]*PLEX_BASE=/d' misterplex.conf
printf '\\nPLEX_BASE=http://192.168.1.24:32400\\n' >> misterplex.conf
sed -i '/^[[:space:]]*STREAM=/d' misterplex.conf
printf 'STREAM=0\\n' >> misterplex.conf
mkdir -p run
printf 'BACKUP=%s\\n' "/media/fat/misterplex/$backup"
md5sum bin/misterplexd
printf '%s\\n' 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd
sync
"""), end="")
    time.sleep(3)
    if main_argv().splitlines() != ["/media/fat/MiSTer", "/media/fat/menu.rbf"]:
        raise RuntimeError("Menu bounce not observed")
    remote(f"printf '%s\\n' 'load_core {REMOTE_RBF}' > /dev/MiSTer_cmd\nsync")
    wait_main(REMOTE_RBF)
    print("FROZEN_BASELINE_CORE_LOADED " + RBF_MD5)


def daemon():
    if REMOTE_RBF not in main_argv().splitlines():
        raise RuntimeError("named frozen core is not active")
    print(remote(f"""
set -eu
cd /media/fat/misterplex
test "$(md5sum bin/misterplexd | cut -d ' ' -f 1)" = "{DAEMON_MD5}"
stream=$(awk -F= '$1=="STREAM" {{v=$2}} END {{print v}}' misterplex.conf)
if [ "$stream" != 0 ]; then
  cp -p misterplex.conf "backups/p0-before-stream0-$(date -u +%Y%m%dT%H%M%SZ).conf"
  for p in $(pidof misterplexd 2>/dev/null || true); do
    test "$(md5sum /proc/$p/exe | cut -d ' ' -f 1)" = "{DAEMON_MD5}"
    parent=$(awk '/^PPid:/ {{print $2}}' /proc/$p/status)
    args=$(tr '\\000' '\\n' < /proc/$parent/cmdline)
    case "$args" in */misterplexd_supervise.sh*) kill -TERM "$parent";; esac
    kill -TERM "$p"
    for i in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$p" 2>/dev/null || break
      sleep 0.5
    done
    if kill -0 "$p" 2>/dev/null; then exit 5; fi
  done
  sed -i '/^[[:space:]]*STREAM=/d' misterplex.conf
  printf '\\nSTREAM=0\\n' >> misterplex.conf
fi
if pidof misterplexd >/dev/null 2>&1; then
  for p in $(pidof misterplexd); do
    test "$(md5sum /proc/$p/exe | cut -d ' ' -f 1)" = "{DAEMON_MD5}"
  done
  echo "Frozen daemon already running"
else
  test -x bin/misterplexd_supervise.sh
  MISTERPLEX_SUP_LOCK=/media/fat/misterplex/run/p0-frozen480p-supervise.lock \\
  TMPDIR=/media/fat/misterplex/run \\
  MISTERPLEXD_BIN=/media/fat/misterplex/bin/misterplexd \\
  MISTERPLEX_ID=misterplex-dev \\
  nohup bin/misterplexd_supervise.sh >> misterplexd_supervise.log 2>&1 < /dev/null &
fi
sleep 2
for p in $(pidof misterplexd); do
  md5sum /proc/$p/exe
done
"""), end="")
    for _ in range(10):
        try:
            body = remote("wget -q -t 1 -T 2 -O - http://127.0.0.1:3005/resources", timeout=8)
            if "<Player" in body:
                print("FROZEN_BASELINE_DAEMON_HTTP_READY " + DAEMON_MD5)
                return
        except (RuntimeError, subprocess.TimeoutExpired):
            pass
        time.sleep(1)
    raise RuntimeError("frozen daemon did not become ready; no fallback binary")


def stop_daemon():
    print(remote(f"""
set -eu
for p in $(pidof misterplexd 2>/dev/null || true); do
  test "$(md5sum /proc/$p/exe | cut -d ' ' -f 1)" = "{DAEMON_MD5}"
  parent=$(awk '/^PPid:/ {{print $2}}' /proc/$p/status)
  args=$(tr '\\000' '\\n' < /proc/$parent/cmdline)
  case "$args" in */misterplexd_supervise.sh*) kill -TERM "$parent";; esac
  kill -TERM "$p"
  for i in $(seq 1 40); do
    kill -0 "$p" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$p" 2>/dev/null; then exit 5; fi
done
echo FROZEN_DAEMON_STOPPED
"""), end="")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in ("core", "daemon", "daemon-stop"):
            raise RuntimeError("use existing deploy entrypoint with --frozen-480p-baseline")
        verify()
        {"core": core, "daemon": daemon, "daemon-stop": stop_daemon}[sys.argv[1]]()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("FROZEN_BASELINE_FAILED: " + str(error), file=sys.stderr)
        sys.exit(1)
