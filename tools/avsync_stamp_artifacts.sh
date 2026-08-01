#!/usr/bin/env bash
# Stamp RBF md5 + daemon md5 for a lipsync measurement (fleet rule).
# Resolve daemon ONLY via readlink /proc/<pid>/exe — never process-name alone
# (cmdline matching hits flock; two install roots exist).
# Does not cast or load cores. Emits JSON on stdout.
set -euo pipefail
HOST="${MISTER_HOST:-192.168.1.183}"
PASS="${MISTER_PASS:-1}"
USER="${MISTER_USER:-root}"
RBF_PATH="${RBF_PATH:-/media/fat/_Utility/Plex.rbf}"

sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  "${USER}@${HOST}" "sh -s" <<REMOTE
set -e
rbf="$RBF_PATH"
rbf_md5="NO-DATA"
rbf_src="NO-DATA"
if [ -f "\$rbf" ]; then
  rbf_md5=\$(md5sum "\$rbf" | awk '{print \$1}')
  rbf_src="measured"
else
  # try common alternate
  for c in /media/fat/Plex.rbf /media/fat/_Utility/Plex.rbf; do
    if [ -f "\$c" ]; then
      rbf="\$c"
      rbf_md5=\$(md5sum "\$c" | awk '{print \$1}')
      rbf_src="measured"
      break
    fi
  done
fi

daemon_pid=""
daemon_exe="NO-DATA"
daemon_md5="NO-DATA"
daemon_src="NO-DATA"
for p in /proc/[0-9]*; do
  pid_n=\${p#/proc/}
  exe=\$(readlink -f "\$p/exe" 2>/dev/null || true)
  case "\$exe" in
    */misterplexd)
      daemon_pid=\$pid_n
      daemon_exe=\$exe
      if [ -f "\$exe" ]; then
        daemon_md5=\$(md5sum "\$exe" | awk '{print \$1}')
        daemon_src="measured"
      fi
      break
      ;;
  esac
done

# decode_src: prefer env/argv note file if present; else NO-DATA (do not invent)
decode_src="NO-DATA"
decode_src_note="not_on_device_fs_as_single_file; parent may pass --decode-src"
if [ -f /tmp/misterplex_decode_src ]; then
  decode_src=\$(cat /tmp/misterplex_decode_src 2>/dev/null | head -1)
  decode_src_note="measured_/tmp/misterplex_decode_src"
fi

# escape for JSON
jesc() { printf '%s' "\$1" | sed 's/\\\\/\\\\\\\\/g; s/"/\\\\"/g'; }

printf '{'
printf '"rbf_path":"%s",' "\$(jesc "\$rbf")"
printf '"rbf_md5":"%s","rbf_md5_src":"%s",' "\$(jesc "\$rbf_md5")" "\$(jesc "\$rbf_src")"
printf '"daemon_pid":"%s",' "\$(jesc "\$daemon_pid")"
printf '"daemon_exe":"%s",' "\$(jesc "\$daemon_exe")"
printf '"daemon_md5":"%s","daemon_md5_src":"%s",' "\$(jesc "\$daemon_md5")" "\$(jesc "\$daemon_src")"
printf '"decode_src":"%s","decode_src_src":"%s",' "\$(jesc "\$decode_src")" "\$(jesc "\$decode_src_note")"
printf '"artifact_pair":"%s+%s",' "\$(jesc "\$rbf_md5")" "\$(jesc "\$daemon_md5")"
printf '"note":"fleet_rule_no_measurement_without_rbf_plus_daemon_md5"'
printf '}\n'
REMOTE
