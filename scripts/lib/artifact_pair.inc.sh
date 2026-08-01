# artifact_pair.inc.sh — every measurement must stamp RBF md5 + daemon md5.
#
# Fleet rule (parent 2026-08-01): judder/soak/CPU numbers without a version
# stamp are not attributable. Call artifact_pair_stamp before publishing.
#
# Manifest: docs/ARTIFACT_PAIR_MANIFEST.md + .agent-work/*/artifact_pair.jsonl
# shellcheck shell=bash

ARTIFACT_PAIR_RBF_MD5="${ARTIFACT_PAIR_RBF_MD5:-}"
ARTIFACT_PAIR_DAEMON_MD5="${ARTIFACT_PAIR_DAEMON_MD5:-}"
ARTIFACT_PAIR_COMMIT="${ARTIFACT_PAIR_COMMIT:-}"
ARTIFACT_PAIR_LABEL="${ARTIFACT_PAIR_LABEL:-}"

artifact_pair_require() {
  # Refuse to publish a measurement without both md5s (or explicit UNSCORED).
  # Always use ${VAR:-} — set -u + unset pair vars must not crash the gate.
  local rbf="${ARTIFACT_PAIR_RBF_MD5:-}"
  local daemon="${ARTIFACT_PAIR_DAEMON_MD5:-}"
  if [[ -z "$rbf" || -z "$daemon" ]]; then
    echo "verdict=UNSCORED reason=missing_artifact_pair rbf=${rbf:-unset} daemon=${daemon:-unset}" >&2
    echo "true rc=77"
    return 77
  fi
  if [[ ! "$rbf" =~ ^[0-9a-fA-F]{32}$ ]]; then
    echo "verdict=FAIL reason=bad_rbf_md5_shape got=${rbf}" >&2
    echo "true rc=2"
    return 2
  fi
  if [[ ! "$daemon" =~ ^[0-9a-fA-F]{32}$ ]]; then
    echo "verdict=FAIL reason=bad_daemon_md5_shape got=${daemon}" >&2
    echo "true rc=2"
    return 2
  fi
  return 0
}

artifact_pair_stamp() {
  local label="${1:-measure}"
  local rbf="${ARTIFACT_PAIR_RBF_MD5:-}"
  local daemon="${ARTIFACT_PAIR_DAEMON_MD5:-}"
  local commit="${ARTIFACT_PAIR_COMMIT:-}"
  ARTIFACT_PAIR_LABEL="$label"
  if [[ -z "$commit" ]] && command -v git >/dev/null 2>&1; then
    commit=$(git rev-parse --short=8 HEAD 2>/dev/null || true)
    ARTIFACT_PAIR_COMMIT="$commit"
  fi
  artifact_pair_require || return $?
  echo "ARTIFACT_PAIR label=${label} rbf_md5=${rbf} daemon_md5=${daemon} commit=${commit:-unknown}"
  return 0
}

# Append one JSONL line for the commit↔md5 manifest (host path; never /tmp).
artifact_pair_append_manifest() {
  local out="${1:?path}"
  local extra="${2:-}"
  mkdir -p "$(dirname "$out")"
  printf '{"ts":"%s","label":"%s","rbf_md5":"%s","daemon_md5":"%s","commit":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${ARTIFACT_PAIR_LABEL:-}" \
    "${ARTIFACT_PAIR_RBF_MD5:-}" \
    "${ARTIFACT_PAIR_DAEMON_MD5:-}" \
    "${ARTIFACT_PAIR_COMMIT:-unknown}" \
    "${extra}" >>"$out"
}
