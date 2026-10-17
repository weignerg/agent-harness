#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh - Cleanly remove installed Agent Harness files
#
# Options:
#   --global (default)       Remove global harness plugins, tools, and rules
#   --local [<repo_path>]    Remove .agents/ and .orchestration/ from repository
#   --purge                  Purge backend virtual environments and configuration directory
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
BACKEND_DIR="${USER_HOME}/.config/opencode-backends"
SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"
SGLANG_STACK_DIR="${USER_HOME}/.local/share/opencode-sglang-stack"

MODE="global"
TARGET_REPO=""
DRY_RUN=false
PURGE=false

show_help() {
    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
        --purge)
            PURGE=true
            shift
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
    echo "[DRY-RUN] SIMULATING uninstallation of agent-harness components..."
    if [ "$PURGE" = true ]; then
        echo "Purging backend stacks and configuration..."
        echo "[DRY-RUN] Would remove directory ${SGLANG_STACK_DIR}"
        echo "[DRY-RUN] Would remove directory ${BACKEND_DIR}"
    fi
    exit 0
fi

if [ "$MODE" = "global" ]; then
    rm -rf "${GEMINI_CONFIG_DIR}/plugins/agy-harness"
    rm -rf "${AGENTS_HOME_DIR}"
    rm -f "${USER_HOME}/AGENTS.md"

    # Clean legacy launchers
    for l in opencode-local opencode-architect-local opencode-worker-local opencode-reviewer-local opencode-sub-agent-local; do
        rm -f "${USER_HOME}/.local/bin/$l"
    done

    # Clean OpenCode configs
    rm -f "${OPENCODE_HOME_DIR}/opencode.json"
    rm -f "${OPENCODE_HOME_DIR}/tui.json"
    rm -f "${OPENCODE_HOME_DIR}/AGENTS.md"
    rm -f "${BACKEND_DIR}/gpu_profile.json"
    rm -f "${BACKEND_DIR}/models_catalog.json"

    # Clean harness systemd user units
    if [ -d "${SYSTEMD_USER_DIR}" ]; then
        for u in "${SYSTEMD_USER_DIR}"/opencode-sglang-*.service "${SYSTEMD_USER_DIR}"/opencode-server.service; do
            if [ -f "$u" ]; then
                rm -f "$u"
            fi
        done
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user daemon-reload 2>/dev/null || true
        fi
    fi

    if [ "$PURGE" = true ]; then
        rm -rf "${SGLANG_STACK_DIR}"
        rm -rf "${BACKEND_DIR}"
        echo "✅ Purged backend stacks and configurations."
    fi
    echo "✅ Removed global harness files."
else
    repo_path="$(mkdir -p "$TARGET_REPO" && cd "$TARGET_REPO" && pwd)"
    rm -rf "${repo_path}/.agents"
    rm -rf "${repo_path}/.orchestration"
    echo "✅ Removed ${repo_path}/.agents and ${repo_path}/.orchestration"
fi
