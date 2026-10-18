#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh - Cleanly remove installed Agent Harness files
#
# Options:
#   --global (default)       Remove global harness plugins, tools, and rules
#   --local [<repo_path>]    Remove .agents/ and .orchestration/ from repository
#   --purge                  Purge backend virtual environments and configuration directory
#   --no-backup              Skip restoring pre-harness backups during uninstall
#   --wipe-backups           Purge .pre-harness.bak files/dirs (requires literal "yes" or -y)
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
NO_BACKUP=false
WIPE_BACKUPS=false
NON_INTERACTIVE=false

show_help() {
    cat << 'EOF'
uninstall.sh - Cleanly remove installed Agent Harness files

Usage:
  ./uninstall.sh [options]

Options:
  --global (default)       Remove global harness plugins, tools, and rules
  --local [<repo_path>]    Remove .agents/ and .orchestration/ from repository
  --purge                  Purge backend virtual environments and configuration directory
  --no-backup              Skip restoring pre-harness backups during uninstall
  --wipe-backups           Purge .pre-harness.bak files/dirs (requires literal "yes" or -y)
  -n, --dry-run            Simulate uninstallation without deleting files
  -y, --yes                Skip confirmation prompts
  -h, --help               Show usage help
EOF
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
        --local=*|--repo=*)
            MODE="local"
            TARGET_REPO="${1#*=}"
            shift
            ;;
        --purge)
            PURGE=true
            shift
            ;;
        --no-backup)
            NO_BACKUP=true
            shift
            ;;
        --wipe-backups)
            WIPE_BACKUPS=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes|--non-interactive)
            NON_INTERACTIVE=true
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

# Wipe backups confirmation gate
if [ "$WIPE_BACKUPS" = true ]; then
    if [ "$NON_INTERACTIVE" != true ]; then
        if [ -t 0 ]; then
            printf "⚠️  WARNING: You are about to permanently purge all .pre-harness.bak backup files and directories.\n"
            printf "Type 'yes' to confirm: "
            read -r confirmation
            if [ "$confirmation" != "yes" ]; then
                echo "❌ Backup wipe cancelled by user."
                exit 1
            fi
        else
            echo "❌ Error: --wipe-backups in non-interactive environment requires -y / --yes flag." >&2
            exit 1
        fi
    fi
fi

if [ "$MODE" = "local" ]; then
    RESOLVED_REPO="$(python3 -c "import os, sys; print(os.path.abspath(sys.argv[1]))" "${TARGET_REPO:-$(pwd)}")"
else
    RESOLVED_REPO=""
fi

# Dual-stream logging setup (only when not dry-run)
if [ "$DRY_RUN" != true ]; then
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    if [ "$MODE" = "local" ]; then
        LOG_DIR="${RESOLVED_REPO}/.orchestration/logs"
    else
        LOG_DIR="${USER_HOME}/.orchestration/logs"
    fi
    mkdir -p "$LOG_DIR"
    LOG_FILE="${LOG_DIR}/uninstall-${TIMESTAMP}.log"
    LATEST_LOG_LINK="${LOG_DIR}/uninstall.log"
    ln -sfn "uninstall-${TIMESTAMP}.log" "$LATEST_LOG_LINK"

    finish_logging() {
        exec 1>&- 2>&-
        wait 2>/dev/null || true
    }
    trap finish_logging EXIT

    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
fi

wipe_pre_harness_backups() {
    local target_dir="$1"
    if [ -d "$target_dir" ]; then
        find "$target_dir" -name "*.pre-harness.bak" 2>/dev/null | while read -r b; do
            if [ -d "$b" ] && [ ! -L "$b" ]; then
                rm -rf "$b"
            else
                rm -f "$b"
            fi
        done
    fi
}

manifest_args=()
[ "$DRY_RUN" = true ] && manifest_args+=(--dry-run)
[ "$NO_BACKUP" = true ] && manifest_args+=(--no-backup)
[ "$WIPE_BACKUPS" = true ] && manifest_args+=(--wipe-backups)

if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] SIMULATING uninstallation of agent-harness components..."
    if [ "$MODE" = "local" ]; then
        manifest_file="${RESOLVED_REPO}/.orchestration/install_manifest.json"
        if [ -f "$manifest_file" ]; then
            python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" "${manifest_args[@]}"
        fi
    else
        manifest_file="${USER_HOME}/.orchestration/install_manifest.json"
        if [ -f "$manifest_file" ]; then
            python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" "${manifest_args[@]}"
        fi
    fi
    if [ "$WIPE_BACKUPS" = true ]; then
        echo "[DRY-RUN] Would purge all .pre-harness.bak backup files and directories"
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
        python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" "${manifest_args[@]}"
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

    # Handle pre-existing settings and backup restoration/wiping
    if [ "$WIPE_BACKUPS" = true ]; then
        rm -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak"
        rm -rf "${AGENTS_HOME_DIR}.pre-harness.bak"
        wipe_pre_harness_backups "${USER_HOME}/.orchestration"
        wipe_pre_harness_backups "${GEMINI_CONFIG_DIR}"
        wipe_pre_harness_backups "${CLAUDE_HOME_DIR}"
        wipe_pre_harness_backups "${OPENCODE_HOME_DIR}"
        echo "✅ Purged pre-harness backup files and directories."
    elif [ "$NO_BACKUP" = false ]; then
        if [ -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak" ]; then
            mv -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak" "${CLAUDE_HOME_DIR}/settings.json"
        fi
        if [ -d "${AGENTS_HOME_DIR}.pre-harness.bak" ] && [ ! -e "${AGENTS_HOME_DIR}" ]; then
            mv -f "${AGENTS_HOME_DIR}.pre-harness.bak" "${AGENTS_HOME_DIR}"
        fi
    fi

    # Clean anchor file
    rm -f "${USER_HOME}/.orchestration/.orchestration_root"

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
    repo_path="$(mkdir -p "$RESOLVED_REPO" && cd "$RESOLVED_REPO" && pwd)"
    manifest_file="${repo_path}/.orchestration/install_manifest.json"
    if [ -f "$manifest_file" ]; then
        python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" "${manifest_args[@]}"
    fi

    # Clean anchor files
    rm -f "${repo_path}/.orchestration_root" "${repo_path}/.orchestration/.orchestration_root"

    # Only remove .agents if it is a symlink
    if [ -L "${repo_path}/.agents" ]; then
        rm -f "${repo_path}/.agents"
    fi

    # Handle pre-existing settings and backup restoration/wiping
    if [ "$WIPE_BACKUPS" = true ]; then
        rm -f "${repo_path}/.claude/settings.json.pre-harness.bak"
        rm -rf "${repo_path}/.agents.pre-harness.bak"
        wipe_pre_harness_backups "${repo_path}/.orchestration"
        wipe_pre_harness_backups "${repo_path}/.claude"
        wipe_pre_harness_backups "${repo_path}/.opencode"
        echo "✅ Purged pre-harness backup files and directories in ${repo_path}."
    elif [ "$NO_BACKUP" = false ]; then
        if [ -f "${repo_path}/.claude/settings.json.pre-harness.bak" ]; then
            mv -f "${repo_path}/.claude/settings.json.pre-harness.bak" "${repo_path}/.claude/settings.json"
        fi
        if [ -d "${repo_path}/.agents.pre-harness.bak" ] && [ ! -e "${repo_path}/.agents" ]; then
            mv "${repo_path}/.agents.pre-harness.bak" "${repo_path}/.agents"
        fi
    fi

    # In local mode, remove uninstaller logs and directories if clean
    if [ -d "${repo_path}/.orchestration/logs" ]; then
        rm -rf "${repo_path}/.orchestration/logs"
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
