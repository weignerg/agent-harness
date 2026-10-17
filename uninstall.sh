#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh - Cleanly remove installed Agent Harness files
#
# Options:
#   --global (default)       Remove global harness plugins, tools, and rules
#   --local [<repo_path>]    Remove .agents/ and .orchestration/ from repository
#   -n, --dry-run            Simulate uninstallation without deleting files
#   -y, --yes                Skip confirmation prompts
#   -h, --help               Show usage help
# ==============================================================================
set -euo pipefail

USER_HOME="${USER_HOME:-${HOME}}"
GEMINI_CONFIG_DIR="${GEMINI_CONFIG_DIR:-${USER_HOME}/.gemini/config}"
AGENTS_HOME_DIR="${AGENTS_HOME_DIR:-${USER_HOME}/.agents}"
CLAUDE_HOME_DIR="${CLAUDE_HOME_DIR:-${USER_HOME}/.claude}"
OPENCODE_HOME_DIR="${OPENCODE_HOME_DIR:-${USER_HOME}/.config/opencode}"

MODE="global"
TARGET_REPO=""
DRY_RUN=false

show_help() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --global)
            MODE="global"
            shift
            ;;
        --local|--repo)
            MODE="local"
            if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                TARGET_REPO="$2"
                shift 2
            else
                TARGET_REPO="$(pwd)"
                shift
            fi
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes|--non-interactive)
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "❌ Error: Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] Would cleanly uninstall agent-harness components"
    exit 0
fi

if [ "$MODE" = "global" ]; then
    rm -rf "${GEMINI_CONFIG_DIR}/plugins/agy-harness"
    rm -rf "${AGENTS_HOME_DIR}"
    echo "✅ Removed global harness files."
else
    repo_path="$(mkdir -p "$TARGET_REPO" && cd "$TARGET_REPO" && pwd)"
    rm -rf "${repo_path}/.agents"
    echo "✅ Removed ${repo_path}/.agents"
fi
