# proc_stat.inc.sh — parse /proc/<pid>/stat AFTER the last ')'.
#
# Parent 2026-08-01: POSIX `$12` is `$1` followed by `2`. `set -- $(cat stat)`
# then `$12`/`$13` silently picks the wrong fields when comm contains spaces
# (comm is inside parentheses and may include spaces). Always split on the
# LAST ')' then take rest-fields 12/13 = utime/stime.
#
# Also: awk '{print $14,$15}' is WRONG when comm has spaces — field numbers
# shift. Same after-')' rule applies inside awk.
#
# shellcheck shell=bash

# Print "utime stime" from a stat file/path or stdin. Exit 2 on malformed.
proc_stat_utime_stime() {
  local f="${1:-}"
  if [[ -n "$f" ]]; then
    awk '
      {
        end = 0
        for (i = length($0); i > 0; i--)
          if (substr($0, i, 1) == ")") { end = i; break }
        if (end == 0) { print "ERR_NO_PAREN"; exit 2 }
        rest = substr($0, end + 2)
        n = split(rest, a, / /)
        # rest: 1=state 2=ppid ... 12=utime 13=stime (man 5 proc)
        if (n < 13) { print "ERR_SHORT n=" n; exit 2 }
        print (a[12] + 0), (a[13] + 0)
        exit 0
      }
    ' "$f"
  else
    awk '
      {
        end = 0
        for (i = length($0); i > 0; i--)
          if (substr($0, i, 1) == ")") { end = i; break }
        if (end == 0) { print "ERR_NO_PAREN"; exit 2 }
        rest = substr($0, end + 2)
        n = split(rest, a, / /)
        if (n < 13) { print "ERR_SHORT n=" n; exit 2 }
        print (a[12] + 0), (a[13] + 0)
        exit 0
      }
    '
  fi
}

# Document the BANNED patterns for static guards / mutations.
proc_stat_banned_patterns() {
  cat <<'EOF'
# BANNED — silent wrong fields when comm has spaces:
#   set -- $(cat /proc/PID/stat); utime=$12; stime=$13
#   set -- $(cat /proc/PID/stat); utime=$14  # still wrong under set--
#   awk '{print $14,$15}' /proc/PID/stat
# REQUIRED:
#   awk after last ')'; rest fields 12/13 = utime/stime
#   or: proc_stat_utime_stime /proc/PID/stat
EOF
}
