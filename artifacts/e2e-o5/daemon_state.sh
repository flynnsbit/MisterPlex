echo "pgrep_count=$(pgrep -c misterplexd 2>/dev/null || echo 0)"
echo "ps_lines:"; ps w 2>/dev/null | grep misterplexd | grep -v grep | head -5
echo "listener_3005:"; (netstat -ltnp 2>/dev/null || ss -ltnp 2>/dev/null) | grep 3005 | head -3
echo "binary:"; ls -l /media/fat/linux/misterplexd 2>/dev/null || echo "  not at /media/fat/linux/misterplexd"
echo "found:"; find /media/fat -maxdepth 3 -name 'misterplexd*' 2>/dev/null | head -5
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
