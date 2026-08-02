# Shared remote sh fragment: resolve live misterplexd install root + log + conf.
# Source into a remote script string — do NOT use as first-hit path list alone.
#
# TWO-ROOTS TRAP (parent 2026-08-01, sixth+ occurrence):
#   /media/fat/misterplex/misterplexd.log can EXIST but be STALE while the live
#   daemon writes /media/fat/misterplex_v2/misterplexd.log. First-hit-wins on a
#   hardcoded list silently reads a dead log → false UNSCORED / wrong epoch.
#
# Rule (parent): resolve LIVE root from /proc — prefer --conf on cmdline, else
#   exe path (*misterplexd*, deleted-tolerant). Never assume v1.
#   pick     = $root/misterplexd.log if present
#   live_conf = --conf arg or $root/misterplex.conf
#   live_root = install root
# Fallback list puts misterplex_v2 BEFORE misterplex (v1). Absence → empty pick.
#
# Sets: pick, live_root, live_conf, live_exe (may be empty).

avsync_resolve_live_log() {
  pick=""
  live_root=""
  live_conf=""
  live_exe=""
  for d in /proc/[0-9]*; do
    [ -r "$d/exe" ] || [ -L "$d/exe" ] || continue
    e=$(readlink -f "$d/exe" 2>/dev/null || readlink "$d/exe" 2>/dev/null || true)
    # Strip Linux "(deleted)" suffix if present
    e=${e% (deleted)}
    # Full cmdline (NUL→NL) for --conf and argv0
    cmd_all=""
    if [ -r "$d/cmdline" ]; then
      cmd_all=$(tr '\0' '\n' <"$d/cmdline" 2>/dev/null || true)
    fi
    a0=$(printf '%s\n' "$cmd_all" | head -n1)
    case "$e" in
      *misterplexd*) ;;
      *)
        case "$a0" in
          *misterplexd*) e=$a0 ;;
          *) continue ;;
        esac
        ;;
    esac
    case "$a0" in
      *live_daemon_enum*|*avsync_stamp*|*avsync_wait*) continue ;;
    esac
    # Prefer --conf path as install-root authority (parent rule).
    conf=""
    prev=""
    while IFS= read -r tok || [ -n "$tok" ]; do
      case "$prev" in
        --conf) conf=$tok; break ;;
      esac
      case "$tok" in
        --conf=*) conf=${tok#--conf=}; break ;;
      esac
      prev=$tok
    done <<CMD
$cmd_all
CMD
    root=""
    if [ -n "$conf" ]; then
      root=$(dirname "$conf")
    fi
    if [ -z "$root" ]; then
      case "$e" in
        */bin/misterplexd) root=${e%/bin/misterplexd} ;;
        */misterplexd) root=$(dirname "$e") ;;
        *) continue ;;
      esac
    fi
    live_exe=$e
    live_root=$root
    if [ -n "$conf" ]; then
      live_conf=$conf
    elif [ -f "$root/misterplex.conf" ]; then
      live_conf=$root/misterplex.conf
    fi
    if [ -n "$root" ] && [ -f "$root/misterplexd.log" ]; then
      pick="$root/misterplexd.log"
      break
    fi
    # Some layouts keep log under log/
    if [ -n "$root" ] && [ -f "$root/log/misterplexd.log" ]; then
      pick="$root/log/misterplexd.log"
      break
    fi
    # Found live process but log missing — still bind root/conf; stop hunting.
    if [ -n "$live_root" ]; then
      break
    fi
  done
  if [ -z "$pick" ]; then
    # Fallback: v2 before v1 — never v1-first
    for f in \
      /tmp/misterplexd.log \
      /var/log/misterplexd.log \
      /tmp/misterplex.log \
      /media/fat/misterplex_v2/misterplexd.log \
      /media/fat/misterplex_v2/log/misterplexd.log \
      /media/fat/misterplex/misterplexd.log \
      /media/fat/misterplex/log/misterplexd.log
    do
      if [ -f "$f" ]; then
        pick=$f
        if [ -z "$live_root" ]; then
          live_root=$(dirname "$f")
          case "$live_root" in
            */log) live_root=$(dirname "$live_root") ;;
          esac
        fi
        if [ -z "$live_conf" ] && [ -f "$live_root/misterplex.conf" ]; then
          live_conf=$live_root/misterplex.conf
        fi
        break
      fi
    done
  fi
}
