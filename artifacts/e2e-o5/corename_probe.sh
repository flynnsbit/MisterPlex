echo "corename=$(cat /tmp/CORENAME 2>/dev/null) uptime=$(cut -d. -f1 /proc/uptime) md5=$(md5sum /media/fat/_Utility/Plex.rbf | cut -c1-8)"
