#!/usr/bin/env bash
# ==============================================================================
# make_linux_installer.sh  --  build the self-extracting Linux installer.
#
#   Output  : <out_dir>/install-agent-harness-v<version>-linux.sh  (default: dist/)
#   Payload : base64( tar.gz( harness config scripts core install.sh ) )
#   Layout  : [self-extract bash header w/ embedded SHA-256]
#             + '#__HARNESS_PKG_EOF__' sentinel line
#             + base64(payload)
#   On run  : awk locates the marker line, decodes base64, verifies SHA-256
#             BEFORE extraction/execution, extracts into a persistent runtime
#             directory (or HARNESS_EXTRACT_DIR), exports
#             AGENT_HARNESS_CANONICAL_ROOT, cd's into it, and execs
#             `bash install.sh "$@"` (args pass-through).
#   Excludes: .git, build/, .venv, uv.lock, tests/, release-build/, __pycache__.
#   Builder scripts are NOT shipped inside the artifact.
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"

_pkg_ver="$(awk -F'"' '/^version[[:space:]]*=[[:space:]]*"/ {print $2; exit}' "${REPO_ROOT}/pyproject.toml")"
VERSION="v${_pkg_ver:-0.7.3}"
ARTIFACT_NAME="install-agent-harness-${VERSION}-linux.sh"
MARKER='#''__HARNESS_PKG_EOF__'

OUT_DIR="${1:-${REPO_ROOT}/dist}"
mkdir -p "${OUT_DIR}"
# Canonicalize OUT_DIR BEFORE changing working directory to REPO_ROOT.
OUT_DIR="$(cd "${OUT_DIR}" && pwd)"

# Payload file tree (relative to the repo root).
PAYLOAD_PATHS=(harness config scripts core install.sh)

cd "${REPO_ROOT}"

_raw="$(mktemp)"
_b64="$(mktemp)"
cleanup() { rm -f "${_raw}" "${_b64}"; }
trap cleanup EXIT

# Build deterministic gzip tarball (no gzip timestamp header) excluding caches/git/tests.
GZIP=-n tar -czf "${_raw}" \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.pyo' \
  --exclude='.DS_Store' \
  --exclude='.git' \
  --exclude='build' \
  --exclude='.venv' \
  --exclude='uv.lock' \
  --exclude='tests' \
  --exclude='release-build' \
  "${PAYLOAD_PATHS[@]}"

base64 < "${_raw}" > "${_b64}"
_payload_sha="$(sha256sum < "${_raw}" | awk '{print $1}')"
_out_file="${OUT_DIR}/${ARTIFACT_NAME}"

{
  printf '#!/usr/bin/env bash\n'
  printf '# ==============================================================================\n'
  printf '# %s  (self-extracting, distro-agnostic)\n' "${ARTIFACT_NAME}"
  cat <<'HDR_TOP'
# Built by release-build/make_linux_installer.sh.
# Decodes the embedded base64(tar.gz) runtime tree, verifies its SHA-256
# checksum BEFORE extraction/execution, extracts it, and runs install.sh.
# ==============================================================================
set -euo pipefail

HDR_TOP
  printf '# HARNESS_PAYLOAD_SHA256=%s\n' "${_payload_sha}"
  printf 'EXPECTED_PAYLOAD_SHA256="%s"\n' "${_payload_sha}"
  cat <<'HDR_BODY'
SNIPPET_MARKER='#''__HARNESS_PKG_EOF__'

# Locate the line immediately after the sentinel marker (stdin redirect avoids '=' path bug).
_start="$(awk -v m="${SNIPPET_MARKER}" '$0==m {print NR+1; exit}' < "$0")"
if [ -z "${_start}" ]; then
  echo "install-agent-harness: payload marker '${SNIPPET_MARKER}' not found in artifact." >&2
  exit 1
fi

_pkg="$(mktemp)"
trap 'rm -f "${_pkg}"' EXIT

# Decode base64 payload (base64 -d is portable across GNU/BSD/BusyBox).
awk "NR>=${_start}" < "$0" | base64 -d > "${_pkg}"

# Verify payload SHA-256 BEFORE extracting or executing install.sh.
if command -v sha256sum >/dev/null 2>&1; then
  _actual_sha="$(sha256sum "${_pkg}" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  _actual_sha="$(shasum -a 256 "${_pkg}" | awk '{print $1}')"
else
  echo "install-agent-harness: neither sha256sum nor shasum found; cannot verify payload integrity." >&2
  exit 1
fi

if [ "${_actual_sha}" != "${EXPECTED_PAYLOAD_SHA256}" ]; then
  echo "install-agent-harness: payload checksum mismatch!" >&2
  echo "  expected: ${EXPECTED_PAYLOAD_SHA256}" >&2
  echo "  actual  : ${_actual_sha}" >&2
  exit 1
fi

# Resolve extraction directory. Use a persistent directory under $HOME by default
# so symlinks created by install.sh survive reboots, or honor HARNESS_EXTRACT_DIR.
if [ -n "${HARNESS_EXTRACT_DIR:-}" ]; then
  mkdir -p "${HARNESS_EXTRACT_DIR}"
  _extract="$(cd "${HARNESS_EXTRACT_DIR}" && pwd)"
elif [ -n "${HOME:-}" ] && mkdir -p "${XDG_DATA_HOME:-${HOME}/.local/share}/agent-harness/runtime" 2>/dev/null; then
  _extract="$(cd "${XDG_DATA_HOME:-${HOME}/.local/share}/agent-harness/runtime" && pwd)"
else
  _extract="$(mktemp -d)"
fi

# Clean prior runtime entries in target extract dir so upgrades leave no stale files.
rm -rf "${_extract}/harness" "${_extract}/config" "${_extract}/scripts" "${_extract}/core" "${_extract}/install.sh"
tar -xzf "${_pkg}" -C "${_extract}"
rm -f "${_pkg}"
trap - EXIT

if [ "${HARNESS_EXTRACT_ONLY:-0}" = "1" ]; then
  printf '%s\n' "${_extract}"
  exit 0
fi

# Pin canonical root to the extracted directory so an unrelated parent .git repo
# (e.g., $HOME/.git dotfiles) cannot hijack install.sh's resolve_canonical_repo_dir().
export AGENT_HARNESS_CANONICAL_ROOT="${AGENT_HARNESS_CANONICAL_ROOT:-${_extract}}"
cd "${_extract}"
exec bash "${_extract}/install.sh" "$@"
HDR_BODY
  printf '%s\n' "${MARKER}"
} > "${_out_file}"

cat "${_b64}" >> "${_out_file}"
chmod +x "${_out_file}"

echo "Wrote ${_out_file}"
echo "  payload gz : $(wc -c < "${_raw}") bytes  sha256=${_payload_sha}"
