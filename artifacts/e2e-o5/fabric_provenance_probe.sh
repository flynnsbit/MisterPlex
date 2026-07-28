# Provenance of the FABRIC, not just the file on disk.
# There is no bitstream readback and no fabric-published build ID, so identity
# is established by ORDERING: if the RBF file was last modified BEFORE the core
# was loaded, the load necessarily read the current file contents.
RBF=/media/fat/_Utility/Plex.rbf
echo "rbf_md5=$(md5sum $RBF | cut -c1-8)"
echo "rbf_mtime_epoch=$(date -r $RBF +%s)"
echo "rbf_mtime=$(date -r $RBF '+%Y-%m-%d %H:%M:%S')"
if [ -f /tmp/CORENAME ]; then
  echo "corename=$(cat /tmp/CORENAME)"
  echo "corename_mtime_epoch=$(date -r /tmp/CORENAME +%s)"
  echo "corename_mtime=$(date -r /tmp/CORENAME '+%Y-%m-%d %H:%M:%S')"
fi
echo "fpga_state=$(cat /sys/class/fpga_manager/fpga0/state 2>/dev/null)"
echo "now_epoch=$(date +%s)"
echo "uptime_s=$(cut -d. -f1 /proc/uptime)"
