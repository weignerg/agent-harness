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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPT_DIR}:${PYTHONPATH:-}"

USER_HOME="${USER_HOME:-${HOME}}"
GEMINI_CONFIG_DIR="${GEMINI_CONFIG_DIR:-${USER_HOME}/.gemini/config}"
AGENTS_HOME_DIR="${AGENTS_HOME_DIR:-${USER_HOME}/.agents}"
CLAUDE_HOME_DIR="${CLAUDE_HOME_DIR:-${USER_HOME}/.claude}"
OPENCODE_HOME_DIR="${OPENCODE_HOME_DIR:-${USER_HOME}/.config/opencode}"
BACKEND_DIR="${USER_HOME}/.config/opencode-backends"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${USER_HOME}/.config/systemd/user}"
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
    if [ "$MODE" = "local" ]; then
        repo_path="$(python3 -c "import os, sys; print(os.path.abspath(sys.argv[1]))" "${TARGET_REPO:-$(pwd)}")"
        manifest_file="${repo_path}/.orchestration/install_manifest.json"
        if [ -f "$manifest_file" ]; then
            python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" --dry-run
        fi
    else
        manifest_file="${USER_HOME}/.orchestration/install_manifest.json"
        if [ -f "$manifest_file" ]; then
            python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" --dry-run
        fi
    fi
    if [ "$PURGE" = true ]; then
        echo "Purging backend stacks and configuration..."
        echo "[DRY-RUN] Would remove directory ${SGLANG_STACK_DIR}"
        echo "[DRY-RUN] Would remove directory ${BACKEND_DIR}"
    fi
    exit 0
fi

if [ "$MODE" = "global" ]; then
    manifest_file="${USER_HOME}/.orchestration/install_manifest.json"
    if [ -f "$manifest_file" ]; then
        python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file"
    else
        # Legacy fallback cleanup for unmanifested installations
        rm -f "${USER_HOME}/AGENTS.md"
        rm -f "${OPENCODE_HOME_DIR}/opencode.json"
        rm -f "${OPENCODE_HOME_DIR}/tui.json"
        rm -f "${OPENCODE_HOME_DIR}/AGENTS.md"
    fi

    # Clean legacy launchers
    for l in opencode-local opencode-architect-local opencode-worker-local opencode-reviewer-local opencode-sub-agent-local; do
        rm -f "${USER_HOME}/.local/bin/$l"
    done

    # Clean harness systemd user units
    if [ -d "${SYSTEMD_USER_DIR}" ]; then
        for u in "${SYSTEMD_USER_DIR}"/opencode-*.service "${SYSTEMD_USER_DIR}"/opencode-*.timer "${SYSTEMD_USER_DIR}"/opencode-*.slice; do
            if [ -f "$u" ]; then
                unit_name="$(basename "$u")"
                if command -v systemctl >/dev/null 2>&1; then
                    systemctl --user stop "$unit_name" 2>/dev/null || true
                    systemctl --user disable "$unit_name" 2>/dev/null || true
                fi
                rm -f "$u"
            fi
        done
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user daemon-reload 2>/dev/null || true
        fi
    fi

    # Clean symlinks
    [ -L "${GEMINI_CONFIG_DIR}/plugins/agy-harness" ] && rm -f "${GEMINI_CONFIG_DIR}/plugins/agy-harness"
    [ -L "${AGENTS_HOME_DIR}" ] && rm -f "${AGENTS_HOME_DIR}"

    # Safely restore pre-existing settings and agents if backup exists
    if [ -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak" ]; then
        mv -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak" "${CLAUDE_HOME_DIR}/settings.json"
    fi
    if [ -d "${AGENTS_HOME_DIR}.pre-harness.bak" ] && [ ! -e "${AGENTS_HOME_DIR}" ]; then
        mv -f "${AGENTS_HOME_DIR}.pre-harness.bak" "${AGENTS_HOME_DIR}"
    fi

    # Safely clean empty directories without wiping user modifications
    for d in "${GEMINI_CONFIG_DIR}/plugins/agent-harness" "${GEMINI_CONFIG_DIR}/plugins/agy-harness" "${USER_HOME}/.orchestration" "${AGENTS_HOME_DIR}" "${CLAUDE_HOME_DIR}" "${OPENCODE_HOME_DIR}"; do
        if [ -d "$d" ]; then
            find "$d" -depth -type d -empty -delete 2>/dev/null || true
            rmdir "$d" 2>/dev/null || true
        fi
    done

    # Remove backend profiles if empty
    rm -f "${BACKEND_DIR}/gpu_profile.json" 2>/dev/null || true
    rm -f "${BACKEND_DIR}/models_catalog.json" 2>/dev/null || true
    rmdir "${BACKEND_DIR}" 2>/dev/null || true

    if [ "$PURGE" = true ]; then
        rm -rf "${SGLANG_STACK_DIR}"
        rm -rf "${BACKEND_DIR}"
        echo "✅ Purged backend stacks and configurations."
    fi
    echo "✅ Removed global harness files."
else
    repo_path="$(mkdir -p "$TARGET_REPO" && cd "$TARGET_REPO" && pwd)"
    manifest_file="${repo_path}/.orchestration/install_manifest.json"
    if [ -f "$manifest_file" ]; then
        python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file"
    fi

    # Restore pre-harness settings backup if present
    if [ -f "${repo_path}/.claude/settings.json.pre-harness.bak" ]; then
        mv -f "${repo_path}/.claude/settings.json.pre-harness.bak" "${repo_path}/.claude/settings.json"
    fi

    # Only remove .agents if it is a symlink
    if [ -L "${repo_path}/.agents" ]; then
        rm -f "${repo_path}/.agents"
    fi

    # Restore pre-harness .agents directory if backed up
    if [ -d "${repo_path}/.agents.pre-harness.bak" ] && [ ! -e "${repo_path}/.agents" ]; then
        mv "${repo_path}/.agents.pre-harness.bak" "${repo_path}/.agents"
    fi

    # Safely clean empty directories only - preserve any user-modified files
    for d in "${repo_path}/.agents" "${repo_path}/.claude" "${repo_path}/.opencode" "${repo_path}/.orchestration"; do
        if [ -d "$d" ]; then
            find "$d" -depth -type d -empty -delete 2>/dev/null || true
            rmdir "$d" 2>/dev/null || true
        fi
    done
    echo "✅ Removed local harness files from ${repo_path}"
fi
