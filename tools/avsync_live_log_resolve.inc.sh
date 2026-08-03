# Shared remote sh fragment: resolve misterplexd.log from the LIVE process.
# Source into a remote script string — do NOT use as first-hit path list alone.
#
# TWO-ROOTS TRAP (parent 2026-08-01, fifth bite):
#   /media/fat/misterplex/misterplexd.log can EXIST but be STALE while the live
#   daemon writes /media/fat/misterplex_v2/misterplexd.log. First-hit-wins on a
#   hardcoded list silently reads a dead log → false UNSCORED / wrong epoch.
#
# Rule: resolve exe via /proc/*/exe (or argv0 *misterplexd*), then
#   root = dirname(dirname(exe)) if .../bin/misterplexd else dirname(exe)
#   pick = $root/misterplexd.log if present.
# Fallback list puts misterplex_v2 BEFORE misterplex (v1). Absence → empty pick.
#
# Emits nothing by itself; sets shell var `pick` (may be empty).

avsync_resolve_live_log() {
  pick=""
  for d in /proc/[0-9]*; do
    [ -r "$d/exe" ] || [ -L "$d/exe" ] || continue
    e=$(readlink -f "$d/exe" 2>/dev/null || readlink "$d/exe" 2>/dev/null || true)
    # Strip Linux "(deleted)" suffix if present
    e=${e% (deleted)}
    a0=""
    if [ -r "$d/cmdline" ]; then
      a0=$(tr '\0' '\n' <"$d/cmdline" 2>/dev/null | head -n1)
    fi
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
    root=""
    case "$e" in
      */bin/misterplexd) root=${e%/bin/misterplexd} ;;
      */misterplexd) root=$(dirname "$e") ;;
      *) continue ;;
    esac
    if [ -n "$root" ] && [ -f "$root/misterplexd.log" ]; then
      pick="$root/misterplexd.log"
      break
    fi
    # Some layouts keep log under log/
    if [ -n "$root" ] && [ -f "$root/log/misterplexd.log" ]; then
      pick="$root/log/misterplexd.log"
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
      if [ -f "$f" ]; then pick=$f; break; fi
    done
  fi
}
