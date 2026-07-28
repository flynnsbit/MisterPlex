#!/usr/bin/env bash
# Publish a status update to the top of STATUS.md.
# Usage: publish.sh <update-file> <commit-msg>
set -euo pipefail
cd /home/flynnsbit/Projects/mp-status
NEW="$1"; MSG="$2"
[ -f "$NEW" ] || { echo "PUBLISH_FAIL no such file: $NEW"; exit 1; }
# Header is lines 1..11 (title, blurb, goal, '---', blank). Updates start at line 12.
grep -q '^## Update' <(sed -n '12p' STATUS.md) || { echo "PUBLISH_FAIL header drift: line 12 is not an update heading"; exit 1; }
{ sed -n '1,11p' STATUS.md; cat "$NEW"; printf '\n---\n\n'; tail -n +12 STATUS.md; } > .s.new
mv .s.new STATUS.md
git add STATUS.md
git -c user.name="MiSTerPlex Orchestrator" \
    -c user.email="223556219+Copilot@users.noreply.github.com" \
    commit -q -m "$MSG

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
git push -q origin status && git push -q origin status
echo "PUBLISH_OK $(git rev-parse --short HEAD) headings=$(grep -c '^## Update' STATUS.md)"
