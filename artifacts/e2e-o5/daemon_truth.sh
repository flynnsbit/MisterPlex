# Oracle A: /proc scan (kernel truth, no external tool)
a=0; for p in /proc/[0-9]*; do
  [ -r "$p/comm" ] || continue
  case "$(cat "$p/comm" 2>/dev/null)" in misterplexd) a=$((a+1)); echo "PROC_PID=${p#/proc/}";; esac
done
echo "ORACLE_A_proc_count=$a"
# Oracle B: listening socket
echo "ORACLE_B=$(netstat -ltn 2>/dev/null | grep -c ':3005 ')"
# Oracle C: FUNCTIONAL - does it answer?
code=$(wget -q -T 5 -O /dev/null -S http://127.0.0.1:3005/status 2>&1 | grep -m1 'HTTP/' | awk '{print $2}')
echo "ORACLE_C_http_status=${code:-NO_RESPONSE}"
echo "ORACLE_C_body=$(wget -q -T 5 -O - http://127.0.0.1:3005/status 2>/dev/null | head -c 200)"
# Tool-presence guard: prove absent tools are reported, not defaulted
for t in pgrep pidof ss; do
  if command -v "$t" >/dev/null 2>&1; then echo "TOOL_$t=present"; else echo "TOOL_$t=ABSENT_UNMEASURABLE"; fi
done
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
