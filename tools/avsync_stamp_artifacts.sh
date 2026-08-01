#!/usr/bin/env bash
# Stamp RBF md5 + daemon md5 (fleet rule — required on every measurement).
# Daemon: md5sum /proc/<pid>/exe ONLY (works on "(deleted)" inodes).
# Identity: argv0 *misterplexd* OR exe *misterplexd* — never cmdline flock match alone.
# Emits JSON on stdout. Does not cast or load cores.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
RBF_PATH="${RBF_PATH:-/media/fat/_Utility/Plex.rbf}"

# shellcheck disable=SC2029
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  "${USER}@${HOST}" "RBF_PATH=$(printf %q "$RBF_PATH") sh -s" <<'REMOTE'
set +e
rbf="${RBF_PATH:-/media/fat/_Utility/Plex.rbf}"
rbf_md5="NO-DATA"
rbf_src="NO-DATA"
if [ -f "$rbf" ]; then
  rbf_md5=$(md5sum "$rbf" | awk '{print $1}')
  rbf_src="measured"
else
  for c in /media/fat/_Utility/Plex.rbf /media/fat/Plex.rbf; do
    if [ -f "$c" ]; then
      rbf="$c"
      rbf_md5=$(md5sum "$c" | awk '{print $1}')
      rbf_src="measured"
      break
    fi
  done
fi

daemon_pid=""
daemon_exe="NO-DATA"
daemon_md5="NO-DATA"
daemon_src="NO-DATA"
n_daemon=0
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  pid_n=${p#/proc/}
  a0=$(tr '\0' '\n' <"$p/cmdline" 2>/dev/null | head -n1)
  exe=$(readlink -f "$p/exe" 2>/dev/null || readlink "$p/exe" 2>/dev/null || true)
  # Prefer argv0 path containing misterplexd; also accept exe *misterplexd* (deleted).
  case "$a0" in
    *misterplexd*) ;;
    *)
      case "$exe" in
        *misterplexd*) ;;
        *) continue ;;
      esac
      ;;
  esac
  case "$a0" in
    *live_daemon_enum*|*avsync_stamp*) continue ;;
  esac
  n_daemon=$((n_daemon + 1))
  # First live daemon wins for stamp; n_daemon reported.
  if [ -z "$daemon_pid" ]; then
    daemon_pid=$pid_n
    daemon_exe=${exe:-NO-DATA}
    # md5 the inode via /proc/PID/exe — works when path shows (deleted)
    if [ -e "$p/exe" ]; then
      daemon_md5=$(md5sum "$p/exe" 2>/dev/null | awk '{print $1}')
      if [ -n "$daemon_md5" ]; then
        daemon_src="measured_proc_exe"
      fi
    fi
  fi
done

decode="NO-DATA"
decode_src="NO-DATA"
decode_src_src="NO-DATA"
# Prefer latest journal/log crumbs if present (best-effort; not required)
for log in /tmp/misterplexd.log /var/log/misterplexd.log /media/fat/misterplex/misterplexd.log \
           /media/fat/misterplex_v2/log/misterplexd.log; do
  if [ -f "$log" ]; then
    line=$(grep -E 'decode_src=' "$log" 2>/dev/null | tail -1)
    if [ -n "$line" ]; then
      decode=$(printf '%s\n' "$line" | sed -n 's/.*decode=\([^ ]*\).*/\1/p' | head -1)
      decode_src=$(printf '%s\n' "$line" | sed -n 's/.*decode_src=\([^ ]*\).*/\1/p' | head -1)
      decode_src_src="measured_log:$(basename "$log")"
      break
    fi
  fi
done

jesc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

pair_ok=0
case "$rbf_md5" in
  [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
    case "$daemon_md5" in
      [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) pair_ok=1 ;;
    esac
    ;;
esac
if [ "$pair_ok" -eq 1 ]; then
  artifact_pair="${rbf_md5}+${daemon_md5}"
  pair_scoreable=1
else
  artifact_pair="UNSCORED_NO_PAIR"
  pair_scoreable=0
fi

printf '{'
printf '"rbf_path":"%s",' "$(jesc "$rbf")"
printf '"rbf_md5":"%s","rbf_md5_src":"%s",' "$(jesc "$rbf_md5")" "$(jesc "$rbf_src")"
printf '"daemon_pid":"%s",' "$(jesc "$daemon_pid")"
printf '"daemon_exe":"%s",' "$(jesc "$daemon_exe")"
printf '"daemon_md5":"%s","daemon_md5_src":"%s",' "$(jesc "$daemon_md5")" "$(jesc "$daemon_src")"
printf '"n_daemon":%s,' "$n_daemon"
printf '"decode":"%s","decode_src":"%s","decode_src_src":"%s",' \
  "$(jesc "$decode")" "$(jesc "$decode_src")" "$(jesc "$decode_src_src")"
printf '"artifact_pair":"%s","pair_scoreable":%s,' "$(jesc "$artifact_pair")" "$pair_scoreable"
printf '"note":"fleet_rule_no_measurement_without_rbf_plus_daemon_md5"'
printf '}\n'
REMOTE
