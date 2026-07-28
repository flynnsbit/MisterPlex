ps w > /tmp/psw.txt 2>&1
echo "total_procs=$(wc -l < /tmp/psw.txt)"
echo "misterplexd_lines=$(grep -c misterplexd /tmp/psw.txt)"
grep misterplexd /tmp/psw.txt
echo "mister_main=$(grep -c '/media/fat/MiSTer' /tmp/psw.txt)"
netstat -lnt 2>/dev/null | grep -c ':3005' || echo "port3005=0"
