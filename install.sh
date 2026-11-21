#!/usr/bin/env bash
# ==============================================================================
# install.sh - Master Unified Agent Harness Installer & Multi-CLI Distribution
#
# Targets:
#   --target [agy|claude|opencode|all]   Deploy runtime integrations (default: all)
#
# Modes:
#   --mode [global|local <path>]         Global user home or local repository (default: global)
#   --global                             Alias for global mode
#   --local [<path>], --repo [<path>]    Alias for local mode into <path>
#
# Actions:
#   --action [install|uninstall|verify]  Action to perform (default: install)
#   --verify                             Verify integrity using install manifest
#   --uninstall                          Safely roll back files using install manifest
#
# Options:
#   -n, --dry-run                        Simulate operations without modifying files
#   -y, --non-interactive                Run without interactive prompts
#   --reinstall                          Force clean re-deployment of harness files
#   --purge                              Purge backend virtual environments (uninstall)
#   -h, --help                           Show usage help
# ==============================================================================
set -euo pipefail

ORIGINAL_ARGS=("$@")
ORIGINAL_CMD="$0"
if [ $# -gt 0 ]; then
    ORIGINAL_CMD="$0 $*"
fi
ORIGINAL_INVOCATION="${ORIGINAL_CMD}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONPATH="${SCRIPT_DIR}:${PYTHONPATH:-}"

resolve_canonical_repo_dir() {
    if [ -n "${AGENT_HARNESS_CANONICAL_ROOT:-}" ]; then
        printf '%s' "${AGENT_HARNESS_CANONICAL_ROOT}"
        return 0
    fi
    local canonical_repo="$SCRIPT_DIR"
    if git -C "$SCRIPT_DIR" rev-parse --git-common-dir >/dev/null 2>&1; then
        local common_git
        common_git="$(cd "$SCRIPT_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd)"
        if [[ "$(basename "$common_git")" == ".git" ]]; then
            canonical_repo="$(dirname "$common_git")"
        fi
    fi
    printf '%s' "$canonical_repo"
}

USER_HOME="${USER_HOME:-${HOME}}"
if [ -n "$USER_HOME" ]; then
    if [ -n "${GEMINI_CONFIG_DIR:-}" ] && [[ "$GEMINI_CONFIG_DIR" != "$USER_HOME"* ]]; then
        GEMINI_CONFIG_DIR="${USER_HOME}/.gemini/config"
    fi
    if [ -n "${SYSTEMD_USER_DIR:-}" ] && [[ "$SYSTEMD_USER_DIR" != "$USER_HOME"* ]]; then
        SYSTEMD_USER_DIR="${USER_HOME}/.config/systemd/user"
    fi
    if [ -n "${CLAUDE_HOME_DIR:-}" ] && [[ "$CLAUDE_HOME_DIR" != "$USER_HOME"* ]]; then
        CLAUDE_HOME_DIR="${USER_HOME}/.claude"
    fi
    if [ -n "${OPENCODE_HOME_DIR:-}" ] && [[ "$OPENCODE_HOME_DIR" != "$USER_HOME"* ]]; then
        OPENCODE_HOME_DIR="${USER_HOME}/.config/opencode"
    fi
    if [ -n "${AGENTS_HOME_DIR:-}" ] && [[ "$AGENTS_HOME_DIR" != "$USER_HOME"* ]]; then
        AGENTS_HOME_DIR="${USER_HOME}/.agents"
    fi
fi
GEMINI_CONFIG_DIR="${GEMINI_CONFIG_DIR:-${USER_HOME}/.gemini/config}"
AGENTS_HOME_DIR="${AGENTS_HOME_DIR:-${USER_HOME}/.agents}"
CLAUDE_HOME_DIR="${CLAUDE_HOME_DIR:-${USER_HOME}/.claude}"
OPENCODE_HOME_DIR="${OPENCODE_HOME_DIR:-${USER_HOME}/.config/opencode}"
BACKEND_DIR="${USER_HOME}/.config/opencode-backends"
SYSTEMD_USER_DIR="${SYSTEMD_USER_DIR:-${USER_HOME}/.config/systemd/user}"
STACK_DIR="${USER_HOME}/.local/share/opencode-sglang-stack"
SGLANG_STACK_DIR="${STACK_DIR}"

TARGET="all"
MODE="global"
ACTION="install"
TARGET_REPO=""
DRY_RUN=false
NON_INTERACTIVE=false
REINSTALL=false
PURGE=false
OVERRIDE_GPU=""
ENABLE_SYSTEMD="${ENABLE_SYSTEMD:-false}"
WITH_OBSIDIAN="${WITH_OBSIDIAN:-true}"
WITH_VAULT="${WITH_VAULT:-true}"
WITH_FIREWALL="${WITH_FIREWALL:-true}"
WITH_BACKENDS="${WITH_BACKENDS:-true}"
DOWNLOAD_MODELS="${DOWNLOAD_MODELS:-}"
SKIP_WARMUP=false
EXPLICIT_WARMUP=false
WITH_HEALTHCHECK="${WITH_HEALTHCHECK:-true}"
EXPLICIT_HEALTHCHECK=false
NO_BACKUP=false
WIPE_BACKUPS=false
ENABLE_T3_SERVE="${ENABLE_T3_SERVE:-true}"
EXPLICIT_WITH_T3=false
EXPLICIT_NO_T3=false
T3_SERVE_WORKDIR="${T3_SERVE_WORKDIR:-}"
SGLANG_MODEL_EXPLICIT=false
if [ -n "${SGLANG_MODEL:-}" ]; then
    SGLANG_MODEL_EXPLICIT=true
fi
SGLANG_MODEL="${SGLANG_MODEL:-ornith-35b}"

SYSTEMD_UNITS=(
    "opencode-server.service"
    "opencode-agent.slice"
    "opencode-colbert-reindex.service"
    "opencode-colbert-reindex.timer"
    "opencode-model-proxy.service"
    "sglang-ornith-1.5-35b.service"
    "sglang-qwen3.8-27b.service"
    "sglang-ornith-1.5-9b.service"
    "t3-serve.service"
)

PROBED_MODEL_NAME=""
PROBED_MODEL_PATH=""
PROBED_SERVICE_NAME=""
PROBED_CONTEXT_LENGTH=""
PROBED_MEM_FRACTION=""
SGLANG_LOCAL_UNSUPPORTED_REASON=""

show_help() {
    cat << 'EOF'
install.sh - Master Unified Agent Harness Installer & Multi-CLI Distribution

Usage:
  ./install.sh [options]

Targets:
  --target agy|claude|opencode|all     Target runtime engine (default: all)

Modes:
  --global                             Deploy plugins & runtime globally to user home (default)
  --mode [global|local <path>]         Specify global or local mode with optional path
  --local [<path>], --repo [<path>]    Deploy into local repository <path> (default: current directory)

Actions:
  --action install|uninstall|verify    Action to execute (default: install)
  --verify                             Verify integrity of files recorded in install manifest
  --uninstall                          Safely roll back installed files using install manifest

Parity & Modules:
  --sglang-model <ornith-35b|qwen3.8|qwen3.8-27b|27b-nvfp4|27b-q6> Select SGLang primary model profile (default: ornith-35b)
  --with-obsidian / --no-obsidian      Toggle Obsidian detection & pacman install (default: with)
  --with-vault / --no-vault            Toggle ~/Vaults/home starter scaffolding (default: with)
  --firewall, --with-firewall / --no-firewall Toggle UFW/iptables rules for ports 4096, 4097, 3773 & 30000 (default: with)
  --with-backends / --no-backends      Toggle SGLang systemd units & backend venv (default: with)
  --with-t3 / --no-t3                  Toggle T3 Code (t3 serve) unified frontend server & unit (default: with)
  --t3-workdir <path>                  Set custom working directory for t3-serve.service (default: user home)
  --download-models / --no-download-models Toggle automatic HF model weights acquisition (default: with backends)
  --skip-warmup / --warmup             Toggle foreground SGLang warmup & live weight download (default: with)
  --healthcheck / --no-healthcheck, --skip-healthcheck Toggle live systemd & port healthcheck verification (default: with)
  --no-backup                          Skip restoring pre-harness backups during uninstall
  --wipe-backups                       Purge .pre-harness.bak files/dirs during uninstall

Options:
  -n, --dry-run                        Simulate operations without modifying files
  -y, --non-interactive                Run without interactive prompts
  --reinstall                          Force clean re-deployment of harness files
  --purge                              Purge backend virtual environments (uninstall)
  -h, --help                           Show usage help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target=*)
            TARGET="${1#*=}"
            shift
            ;;
        --target|--runtime)
            TARGET="$2"
            shift 2
            ;;
        --mode=*)
            val="${1#*=}"
            if [[ "$val" == "global" ]]; then
                MODE="global"
                shift
            elif [[ "$val" == "local" || "$val" == "repo" ]]; then
                MODE="local"
                if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
                    TARGET_REPO="$2"
                    shift 2
                else
                    TARGET_REPO="$(pwd)"
                    shift
                fi
            else
                shift
            fi
            ;;
        --mode)
            if [[ "$2" == "global" ]]; then
                MODE="global"
                shift 2
            elif [[ "$2" == "local" || "$2" == "repo" ]]; then
                MODE="local"
                if [[ $# -gt 2 && ! "$3" =~ ^- ]]; then
                    TARGET_REPO="$3"
                    shift 3
                else
                    TARGET_REPO="$(pwd)"
                    shift 2
                fi
            else
                echo "❌ Error: Unknown mode: $2" >&2
                exit 1
            fi
            ;;
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
        --action=*)
            ACTION="${1#*=}"
            shift
            ;;
        --action)
            ACTION="$2"
            shift 2
            ;;
        --verify)
            ACTION="verify"
            shift
            ;;
        --uninstall)
            ACTION="uninstall"
            shift
            ;;
        --purge)
            PURGE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--non-interactive|--yes)
            NON_INTERACTIVE=true
            shift
            ;;
        --reinstall)
            REINSTALL=true
            shift
            ;;
        --override-gpu)
            OVERRIDE_GPU="$2"
            shift 2
            ;;
        --override-gpu=*)
            OVERRIDE_GPU="${1#*=}"
            shift
            ;;
        --sglang-model)
            SGLANG_MODEL="$2"
            SGLANG_MODEL_EXPLICIT=true
            shift 2
            ;;
        --sglang-model=*)
            SGLANG_MODEL="${1#*=}"
            SGLANG_MODEL_EXPLICIT=true
            shift
            ;;
        --systemd|--with-systemd)
            ENABLE_SYSTEMD=true
            shift
            ;;
        --with-obsidian)
            WITH_OBSIDIAN=true
            shift
            ;;
        --no-obsidian)
            WITH_OBSIDIAN=false
            shift
            ;;
        --with-vault)
            WITH_VAULT=true
            shift
            ;;
        --no-vault)
            WITH_VAULT=false
            shift
            ;;
        --with-firewall)
            WITH_FIREWALL=true
            shift
            ;;
        --no-firewall)
            WITH_FIREWALL=false
            shift
            ;;
        --with-backends)
            WITH_BACKENDS=true
            shift
            ;;
        --no-backends)
            WITH_BACKENDS=false
            shift
            ;;
        --with-t3)
            ENABLE_T3_SERVE=true
            EXPLICIT_WITH_T3=true
            EXPLICIT_NO_T3=false
            shift
            ;;
        --no-t3|--without-t3)
            ENABLE_T3_SERVE=false
            EXPLICIT_NO_T3=true
            EXPLICIT_WITH_T3=false
            shift
            ;;
        --t3-workdir)
            T3_SERVE_WORKDIR="$2"
            shift 2
            ;;
        --t3-workdir=*)
            T3_SERVE_WORKDIR="${1#*=}"
            shift
            ;;
        --download-models|--with-download-models)
            DOWNLOAD_MODELS=true
            shift
            ;;
        --no-download-models|--without-download-models)
            DOWNLOAD_MODELS=false
            shift
            ;;
        --skip-warmup|--no-warmup|--without-warmup)
            SKIP_WARMUP=true
            EXPLICIT_WARMUP=false
            shift
            ;;
        --warmup|--with-warmup)
            SKIP_WARMUP=false
            EXPLICIT_WARMUP=true
            shift
            ;;
        --healthcheck|--with-healthcheck)
            WITH_HEALTHCHECK=true
            EXPLICIT_HEALTHCHECK=true
            shift
            ;;
        --no-healthcheck|--without-healthcheck|--skip-healthcheck)
            WITH_HEALTHCHECK=false
            EXPLICIT_HEALTHCHECK=false
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
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "❌ Error: Unknown argument: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

if [ -z "$DOWNLOAD_MODELS" ]; then
    if [ "$WITH_BACKENDS" = true ]; then
        DOWNLOAD_MODELS=true
    else
        DOWNLOAD_MODELS=false
    fi
fi

if [ "$MODE" = "global" ]; then
    ENABLE_SYSTEMD=true
fi

# Resolve TARGET_REPO
if [ "$MODE" = "local" ]; then
    if [ -z "$TARGET_REPO" ]; then
        TARGET_REPO="$(pwd)"
    fi
    if [ "$DRY_RUN" = true ]; then
        TARGET_REPO="$(python3 -c "import os, sys; print(os.path.abspath(sys.argv[1]))" "$TARGET_REPO")"
    else
        TARGET_REPO="$(mkdir -p "$TARGET_REPO" && cd "$TARGET_REPO" && pwd)"
    fi
fi

# Wipe backups confirmation gate for uninstallation
if [ "$WIPE_BACKUPS" = true ] && [ "$ACTION" = "uninstall" ]; then
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

# Dual-stream logging setup
if [ "$DRY_RUN" != true ]; then
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    if [ "$MODE" = "local" ]; then
        LOG_DIR="${TARGET_REPO}/.orchestration/logs"
    else
        LOG_DIR="${USER_HOME}/.orchestration/logs"
    fi
    mkdir -p "$LOG_DIR"
    if [ "$ACTION" = "uninstall" ]; then
        LOG_FILE="${LOG_DIR}/uninstall-${TIMESTAMP}.log"
        LATEST_LOG_LINK="${LOG_DIR}/uninstall.log"
        ln -sfn "uninstall-${TIMESTAMP}.log" "$LATEST_LOG_LINK"
    else
        LOG_FILE="${LOG_DIR}/install-${TIMESTAMP}.log"
        LATEST_LOG_LINK="${LOG_DIR}/install.log"
        ln -sfn "install-${TIMESTAMP}.log" "$LATEST_LOG_LINK"
    fi

    finish_logging() {
        exec 1>&- 2>&-
        wait 2>/dev/null || true
    }
    trap finish_logging EXIT

    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
fi

PENDING_SUDO_COMMANDS=()

run_sudo() {
    local cmd=("$@")
    local cmd_str="${cmd[*]}"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would execute with sudo: sudo ${cmd_str}"
        return 0
    fi

    # Check if passwordless sudo is permitted
    if sudo -n true 2>/dev/null; then
        sudo "${cmd[@]}"
        return $?
    fi

    # Check if running interactively
    if [ -t 0 ] && [ "$NON_INTERACTIVE" != true ]; then
        if sudo -v 2>/dev/null; then
            sudo "${cmd[@]}"
            return $?
        fi
    fi

    # Non-interactive shell OR no passwordless sudo privilege
    PENDING_SUDO_COMMANDS+=("$cmd_str")

    # Prominent warning directly to stderr
    cat << EOF >&2
⚠️  ========================================================================
⚠️  SUDO PRIVILEGE REQUIRED - NON-INTERACTIVE / NON-ROOT ENVIRONMENT
⚠️  ========================================================================
⚠️  The following root command could not be executed automatically:
⚠️      sudo ${cmd_str}
⚠️
⚠️  INSTALLATION IS INCOMPLETE WITHOUT MANUAL ROOT INTERVENTION.
⚠️  Please execute the manual root command above to complete this step.
⚠️  ========================================================================
EOF

    # Also log clearly to stdout and install log
    echo "⚠️  [PENDING ROOT ACTION] Installation is INCOMPLETE without manual intervention."
    echo "    To complete this step, run: sudo ${cmd_str}"

    return 0
}

print_pending_sudo_summary() {
    if [ ${#PENDING_SUDO_COMMANDS[@]} -gt 0 ]; then
        cat << 'EOF' >&2

❌ ========================================================================
❌ ATTENTION: INSTALLATION INCOMPLETE - MANUAL INTERVENTION REQUIRED
❌ ========================================================================
The installer completed non-root configuration steps, but one or more
actions required root privileges in a non-interactive environment.

Please run the following commands manually to complete setup:
EOF
        for c in "${PENDING_SUDO_COMMANDS[@]}"; do
            echo "  sudo $c" >&2
        done
        cat << 'EOF' >&2
========================================================================
EOF

        echo ""
        echo "❌ ========================================================================"
        echo "❌ ATTENTION: INSTALLATION INCOMPLETE - MANUAL INTERVENTION REQUIRED"
        echo "❌ ========================================================================"
        echo "The installer completed non-root configuration steps, but one or more"
        echo "actions required root privileges in a non-interactive environment."
        echo ""
        echo "Please run the following commands manually to complete setup:"
        for c in "${PENDING_SUDO_COMMANDS[@]}"; do
            echo "  sudo $c"
        done
        echo "========================================================================"
    fi
}

install_obsidian() {
    echo "================================================================================"
    echo "📦 CONFIGURING OBSIDIAN DESKTOP KNOWLEDGE VAULT"
    echo "================================================================================"
    if [ "$WITH_OBSIDIAN" != true ]; then
        echo "  ℹ️  Obsidian installation skipped (--no-obsidian)."
        return 0
    fi

    local obsidian_installed=false
    local obsidian_path=""
    if command -v obsidian >/dev/null 2>&1; then
        obsidian_installed=true
        obsidian_path="$(command -v obsidian)"
    elif command -v flatpak >/dev/null 2>&1 && flatpak list 2>/dev/null | grep -qi "obsidian"; then
        obsidian_installed=true
        obsidian_path="Flatpak (md.obsidian.Obsidian)"
    fi

    if [ "$obsidian_installed" = true ]; then
        echo "  ✅ Obsidian Knowledge Vault manager already installed: ${obsidian_path}"
    else
        echo "  📦 Installing Obsidian Knowledge Vault manager via pacman..."
        if command -v pacman >/dev/null 2>&1; then
            run_sudo pacman -S --needed --noconfirm obsidian
        elif command -v flatpak >/dev/null 2>&1; then
            echo "  ℹ️  Pacman not available; flatpak detected. To install via Flatpak:"
            echo "      flatpak install -y flathub md.obsidian.Obsidian"
        else
            echo "  ℹ️  No supported package manager found for automatic Obsidian install."
        fi
    fi
}

provision_home_vault() {
    echo "================================================================================"
    echo "📚 PROVISIONING KNOWLEDGE VAULT (~/Vaults/home)"
    echo "================================================================================"
    if [ "$WITH_VAULT" != true ]; then
        echo "  ℹ️  Vault scaffolding skipped (--no-vault)."
        return 0
    fi

    local template_vault="${SCRIPT_DIR}/vault"
    local home_vault="${USER_HOME}/Vaults/home"
    local repos_root="${USER_HOME}/Vaults/repos"

    if [ ! -d "$template_vault" ]; then
        echo "  ⚠️  Repository vault templates not found at ${template_vault}; skipping."
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would scaffold ${home_vault} and ${repos_root} from ${template_vault}"
        return 0
    fi

    mkdir -p "${home_vault}/entities" "${home_vault}/templates" \
             "${home_vault}/decisions" "${home_vault}/protocols" \
             "${home_vault}/projects" "${home_vault}/.obsidian" "$repos_root"

    local populated=false
    if [ -n "$(find "${home_vault}" -type f ! -path "*/.index/*" 2>/dev/null)" ]; then
        populated=true
    fi

    while IFS= read -r src; do
        rel="${src#"${template_vault}"/}"
        case "$rel" in
            *.index/*) continue ;;
        esac
        local dest="${home_vault}/${rel}"
        if [ ! -e "$dest" ]; then
            mkdir -p "$(dirname "$dest")"
            cp -p "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
        fi
    done < <(find "$template_vault" -type f)

    if [ "$populated" = true ]; then
        echo "  ✅ ~/Vaults/home verified and populated with missing templates."
    else
        echo "  ✅ Provisioned ~/Vaults/home from starter templates (repos skeleton created)."
    fi
}

configure_firewall() {
    echo "================================================================================"
    echo "🛡️ CONFIGURING LOCAL FIREWALL RULES (PORTS 4096, 4097, 3773 & 30000)"
    echo "================================================================================"
    if [ "$WITH_FIREWALL" != true ]; then
        echo "  ℹ️  Firewall rule management skipped (--no-firewall)."
        return 0
    fi

    if command -v ufw >/dev/null 2>&1; then
        echo "  Applying UFW firewall rules for ports 4096/tcp, 4097/tcp, 3773/tcp, and 30000/tcp..."
        run_sudo ufw allow 4096/tcp comment 'OpenCode Server'
        run_sudo ufw allow 4097/tcp comment 'OpenCode Server Alt'
        run_sudo ufw allow 3773/tcp comment 'T3 Code Unified Server'
        run_sudo ufw allow 30000/tcp comment 'OpenCode SGLang Server'
        echo "  ✅ UFW rules processed."
    elif command -v iptables >/dev/null 2>&1; then
        echo "  Applying iptables rules for ports 4096/tcp, 4097/tcp, 3773/tcp, and 30000/tcp..."
        run_sudo iptables -I INPUT -p tcp --dport 4096 -j ACCEPT
        run_sudo iptables -I INPUT -p tcp --dport 4097 -j ACCEPT
        run_sudo iptables -I INPUT -p tcp --dport 3773 -j ACCEPT
        run_sudo iptables -I INPUT -p tcp --dport 30000 -j ACCEPT
        echo "  ✅ iptables rules processed."
    else
        echo "  ℹ️  Neither UFW nor iptables detected; skipping firewall rules."
    fi
}

ensure_gitignore_entries() {
    local gitignore_file="$1"
    shift
    local entries=("$@")

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Ensure ${gitignore_file} ignores: ${entries[*]}"
        return 0
    fi

    touch "$gitignore_file"
    [ -s "$gitignore_file" ] && [ -n "$(tail -c1 "$gitignore_file")" ] && echo "" >> "$gitignore_file"
    for entry in "${entries[@]}"; do
        if ! grep -qxF "$entry" "$gitignore_file" 2>/dev/null; then
            echo "$entry" >> "$gitignore_file"
            echo "  ✅ Added '${entry}' to ${gitignore_file}"
        fi
    done
}

# --- GLOBAL TARGET INSTALLERS -------------------------------------------------

# Remove symlinks in <dir> that point into <harness_src_dir> (harness-owned); leaves everything else intact.
prune_harness_links() {
    local dir="$1"
    local harness_src="$2"
    [ -d "$dir" ] || return 0
    local entry target
    for entry in "$dir"/*; do
        [ -L "$entry" ] || continue
        target="$(readlink "$entry")"
        case "$target" in
            "${harness_src}"/*|"${harness_src}") rm -f "$entry" ;;
        esac
    done
    rmdir "$dir" 2>/dev/null || true
}

# Workspace root instruction entrypoints. Real (user-authored) files are never overwritten; only
# missing paths or previously harness-created symlinks are (re)linked.
link_workspace_entrypoint() {
    local link_path="$1" link_target="$2"
    if [ -e "$link_path" ] && [ ! -L "$link_path" ]; then
        echo "  ⚠️ Keeping existing ${link_path} (not a symlink); harness entrypoint not linked"
        return 0
    fi
    ln -sfn "$link_target" "$link_path"
}

link_workspace_entrypoints() {
    local target_repo="$1"
    [ -d "$target_repo" ] || return 0
    local canonical_repo="$(resolve_canonical_repo_dir)"
    local core_dir="${SCRIPT_DIR}/core"
    [ -d "$core_dir" ] || core_dir="${canonical_repo}/core"

    local agents_target=".orchestration/AGENTS.md"
    if [ -f "${target_repo}/.orchestration/AGENTS.md" ]; then
        agents_target=".orchestration/AGENTS.md"
    elif [ -f "${target_repo}/.agents/AGENTS.md" ]; then
        agents_target=".agents/AGENTS.md"
    elif [ -f "${core_dir}/CHARTER.md" ]; then
        agents_target="${core_dir}/CHARTER.md"
    fi

    local gemini_target=".orchestration/GEMINI.md"
    if [ -f "${target_repo}/.orchestration/GEMINI.md" ]; then
        gemini_target=".orchestration/GEMINI.md"
    elif [ -f "${target_repo}/.agents/GEMINI.md" ]; then
        gemini_target=".agents/GEMINI.md"
    elif [ -f "${canonical_repo}/config/agy/GEMINI.md" ]; then
        gemini_target="${canonical_repo}/config/agy/GEMINI.md"
    fi

    link_workspace_entrypoint "${target_repo}/AGENTS.md" "$agents_target"
    link_workspace_entrypoint "${target_repo}/GEMINI.md" "$gemini_target"
    link_workspace_entrypoint "${target_repo}/CLAUDE.md" "AGENTS.md"
}

sync_t3_antigravity_providers() {
    local user_home="$1"
    local gemini_dir="$2"
    local orch_dest="$3"
    local t3_providers_dir="${user_home}/.t3/userdata/providers/antigravity"

    local default_hash="ac0a3dfd6dddb20962cecff6ee5fe65e19d3923be20e52c5ab52ff877f7e4c32"
    local target_dirs=()

    if [ -d "$t3_providers_dir" ]; then
        for d in "${t3_providers_dir}"/*; do
            if [ -d "$d" ]; then
                target_dirs+=("$d")
            fi
        done
    fi

    if [ -d "${user_home}/.t3" ]; then
        local default_prov="${t3_providers_dir}/${default_hash}"
        mkdir -p "${default_prov}/config" "${default_prov}/antigravity-cli"
        local found=false
        for d in "${target_dirs[@]}"; do
            [ "$d" = "$default_prov" ] && found=true && break
        done
        [ "$found" = false ] && target_dirs+=("$default_prov")
    fi

    if [ ${#target_dirs[@]} -eq 0 ]; then
        return 0
    fi

    for inst_dir in "${target_dirs[@]}"; do
        mkdir -p "${inst_dir}/config"
        [ -f "${gemini_dir}/GEMINI.md" ] && ln -sfn "${gemini_dir}/GEMINI.md" "${inst_dir}/GEMINI.md"
        [ -f "${gemini_dir}/AGENTS.md" ] && ln -sfn "${gemini_dir}/AGENTS.md" "${inst_dir}/AGENTS.md"
        [ -d "${gemini_dir}/config/rules" ] && ln -sfn "${gemini_dir}/config/rules" "${inst_dir}/config/rules"
        [ -d "${gemini_dir}/config/plugins" ] && ln -sfn "${gemini_dir}/config/plugins" "${inst_dir}/config/plugins"
        [ -f "${gemini_dir}/config/mcp_config.json" ] && ln -sfn "${gemini_dir}/config/mcp_config.json" "${inst_dir}/config/mcp_config.json"
        if [ -d "${orch_dest}/skills" ]; then
            ln -sfn "${orch_dest}/skills" "${inst_dir}/config/skills"
        elif [ -d "${gemini_dir}/config/skills" ]; then
            ln -sfn "${gemini_dir}/config/skills" "${inst_dir}/config/skills"
        fi
    done
    echo "  ✅ Synced harness charters, rules, and plugins into T3 Code Antigravity providers"
}

install_agy_global() {
    local gemini_dir="${USER_HOME}/.gemini"
    local plugin_dest="${GEMINI_CONFIG_DIR}/plugins/agent-harness"
    local legacy_agy_plugin="${GEMINI_CONFIG_DIR}/plugins/agy-harness"
    local legacy_plugin="${GEMINI_CONFIG_DIR}/plugins/local-blackwell"
    local mcp_config="${GEMINI_CONFIG_DIR}/mcp_config.json"
    local agy_settings="${gemini_dir}/antigravity-cli/settings.json"
    local gemini_md="${gemini_dir}/GEMINI.md"
    local global_agents_md="${gemini_dir}/AGENTS.md"
    local orch_dest="${USER_HOME}/.orchestration"
    local agents_link="${USER_HOME}/.agents"
    local canonical_repo="$(resolve_canonical_repo_dir)"
    local core_dir="${SCRIPT_DIR}/core"
    [ -d "$core_dir" ] || core_dir="${canonical_repo}/core"
    local py_bin="python3"
    if [ -x "${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
        py_bin="${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
    fi

    echo "================================================================================"
    echo "🚀 INSTALLING AGY HARNESS (GLOBAL MODE)"
    echo "   Plugin Target : ${plugin_dest}"
    echo "   Agents Target : ${AGENTS_HOME_DIR}"
    echo "   Orchestration : ${orch_dest}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would remove legacy ${legacy_plugin} and ${legacy_agy_plugin}"
        echo "  [DRY-RUN] Would compile agents from ${core_dir}/agents to ${plugin_dest}/agents/"
        echo "  [DRY-RUN] Would expose canonical skills once via the plugin at ${plugin_dest}/skills/ (no duplicate global copies)"
        echo "  [DRY-RUN] Would symlink modular rules to ${GEMINI_CONFIG_DIR}/rules/"
        echo "  [DRY-RUN] Would deploy canonical ${global_agents_md} and compact AGY addendum block in ${gemini_md}"
        echo "  [DRY-RUN] Would register vault-memory and worktree-manager in ${mcp_config}"
        return 0
    fi

    rm -rf "$legacy_plugin"
    rm -rf "$legacy_agy_plugin"
    rm -f "${USER_HOME}/AGENTS.md"

    if [ -d "${USER_HOME}/.agent" ] && [ ! -L "${USER_HOME}/.agent" ]; then
        local bak_agent="${USER_HOME}/.agent.pre-harness.bak"
        if [ ! -e "$bak_agent" ]; then
            mv "${USER_HOME}/.agent" "$bak_agent"
            echo "  ⚠️ Warning: Pre-existing legacy ~/.agent directory backed up to ${bak_agent}"
        fi
    elif [ -L "${USER_HOME}/.agent" ]; then
        rm -f "${USER_HOME}/.agent"
    fi

    mkdir -p "${gemini_dir}"
    ln -sfn "${core_dir}/CHARTER.md" "${global_agents_md}"

    mkdir -p "${plugin_dest}/agents"
    mkdir -p "${plugin_dest}/skills"
    cp -f "${canonical_repo}/config/agy/plugins/agent-harness/plugin.json" "${plugin_dest}/plugin.json" 2>/dev/null || cat <<'EOF' > "${plugin_dest}/plugin.json"
{
  "name": "agent-harness",
  "version": "1.0.0",
  "description": "Unified Multi-Runtime Agent Harness for Google Antigravity",
  "agents": "agents"
}
EOF

    python3 -m harness.installer.compiler \
        --core-dir "${core_dir}" \
        --runtime agy \
        --output-dir "${plugin_dest}/agents"

    mkdir -p "$(dirname "$legacy_agy_plugin")"
    ln -sfn agent-harness "${legacy_agy_plugin}"
    echo "  ✅ Installed canonical Gemini 3.8 agent profiles in ${plugin_dest}/agents/"

    # Skills are exposed exactly once, through the plugin. Linking the same skills into ~/.gemini/config/skills/
    # (or any other directory) makes AGY list every skill twice and wastes customization budget. Prune any
    # harness-owned links left behind by earlier installer versions (third-party skills are never touched).
    find "${plugin_dest}/skills" -xtype l -delete 2>/dev/null || true
    for stale_dir in "${GEMINI_CONFIG_DIR}/skills" "${gemini_dir}/antigravity/skills"; do
        prune_harness_links "$stale_dir" "${core_dir}/skills"
    done
    for skill_path in "${core_dir}/skills"/*; do
        if [ -d "$skill_path" ]; then
            ln -sfn "$skill_path" "${plugin_dest}/skills/$(basename "$skill_path")"
        fi
    done
    echo "  ✅ Symlinked canonical skills into the agent-harness plugin"

    # Modular always_on rules: the documented global location is ~/.gemini/config/rules/. The undocumented
    # ~/.gemini/antigravity-cli/rules/ copy from earlier versions is pruned.
    local agy_cfg_rules="${GEMINI_CONFIG_DIR}/rules"
    mkdir -p "${agy_cfg_rules}"
    find "${agy_cfg_rules}" -xtype l -delete 2>/dev/null || true
    prune_harness_links "${gemini_dir}/antigravity-cli/rules" "${core_dir}/rules"
    for r in "${core_dir}/rules"/*.md; do
        [ -f "$r" ] || continue
        ln -sfn "$r" "${agy_cfg_rules}/$(basename "$r")"
    done
    echo "  ✅ Installed modular rules into ${agy_cfg_rules}"

    mkdir -p "${orch_dest}/rules" "${orch_dest}/skills" "${orch_dest}/tools" "${orch_dest}/handoffs" "${orch_dest}/orchestration" "${orch_dest}/memory" "${orch_dest}/worktrees" "${orch_dest}/logs" "${orch_dest}/tmp"
    find "${orch_dest}/rules" -xtype l -delete 2>/dev/null || true
    for r in "${core_dir}/rules"/*.md; do
        [ -f "$r" ] || continue
        ln -sfn "$r" "${orch_dest}/rules/$(basename "$r")"
    done
    for skill_path in "${core_dir}/skills"/*; do
        if [ -d "$skill_path" ]; then
            ln -sfn "$skill_path" "${orch_dest}/skills/$(basename "$skill_path")"
        fi
    done
    for tool_path in "${canonical_repo}/scripts"/*.py "${canonical_repo}/scripts"/*.sh; do
        [ -f "$tool_path" ] || continue
        ln -sfn "$tool_path" "${orch_dest}/tools/$(basename "$tool_path")"
        chmod +x "$tool_path" 2>/dev/null || true
    done
    cp -rf "${canonical_repo}/config/orchestration/"* "${orch_dest}/orchestration/" 2>/dev/null || true
    touch "${orch_dest}/handoffs/.gitkeep"
    ln -sfn "${core_dir}/CHARTER.md" "${orch_dest}/AGENTS.md"
    ln -sfn "${canonical_repo}/config/agy/GEMINI.md" "${orch_dest}/GEMINI.md"

    if [ -L "${agents_link}" ]; then
        rm -f "${agents_link}"
    elif [ -d "${agents_link}" ]; then
        if [ -d "${agents_link}/skills" ]; then
            cp -rn "${agents_link}/skills/"* "${orch_dest}/skills/" 2>/dev/null || true
        fi
        local bak_agents="${agents_link}.pre-harness.bak"
        if [ ! -e "$bak_agents" ]; then
            cp -r "$agents_link" "$bak_agents"
            echo "  ⚠️ Warning: Pre-existing directory ${agents_link} backed up to ${bak_agents}"
        fi
        rm -rf "$agents_link"
    elif [ -e "${agents_link}" ]; then
        local bak_agents="${agents_link}.pre-harness.bak"
        mv "$agents_link" "$bak_agents"
    fi
    ln -sfn "${orch_dest}" "${agents_link}"
    echo "  ✅ Synced rules, skills, tools, and charters to ${orch_dest}/ and linked ${agents_link}"

    python3 -m harness.installer.config_sync sync-gemini \
        --gemini-md "${gemini_md}" \
        --charter "${core_dir}/CHARTER.md" \
        --rules-dir "${core_dir}/rules" \
        --template "${canonical_repo}/config/agy/GEMINI.md"

    python3 -m harness.installer.config_sync sync-agy-mcp \
        --mcp-config "${mcp_config}" \
        --repo-dir "${canonical_repo}" \
        --py-bin "${py_bin}" \
        --orch-dir "${orch_dest}"

    # Undocumented duplicate MCP/settings files written by earlier installer versions would register the
    # same servers twice (or pollute the Gemini CLI settings); remove only what the harness created.
    if [ -f "${gemini_dir}/antigravity/mcp_config.json" ] && grep -q '"harness.mcp.vault_server"' "${gemini_dir}/antigravity/mcp_config.json" 2>/dev/null \
        && ! grep -q '"rea"' "${gemini_dir}/antigravity/mcp_config.json" 2>/dev/null; then
        rm -f "${gemini_dir}/antigravity/mcp_config.json"
    fi
    python3 -m harness.installer.config_sync prune-legacy-settings --settings-path "${gemini_dir}/settings.json" --repo-dir "${canonical_repo}" --orch-dir "${orch_dest}" || true

    if [ -f "${agy_settings}" ]; then
        python3 -m harness.installer.config_sync sync-agy-settings \
            --settings-path "${agy_settings}" \
            --repo-dir "${canonical_repo}" \
            --orch-dir "${orch_dest}"
    fi
    echo "  ✅ Registered vault-memory and worktree-manager in ${mcp_config}"

    # Sync canonical AGY configuration into any T3 Code Antigravity provider sandboxes
    sync_t3_antigravity_providers "${USER_HOME}" "${gemini_dir}" "${orch_dest}"

    # Ensure repository workspace has entrypoint links for T3 Code / native discovery
    if [ -d "$canonical_repo" ]; then
        link_workspace_entrypoints "$canonical_repo"
    fi
}

install_claude_global() {
    local claude_dest="${CLAUDE_HOME_DIR}"
    local claude_json="${USER_HOME}/.claude.json"
    local claude_cfg="${SCRIPT_DIR}/config/claude"
    local canonical_repo="$(resolve_canonical_repo_dir)"
    local core_dir="${SCRIPT_DIR}/core"
    [ -d "$core_dir" ] || core_dir="${canonical_repo}/core"
    local orch_dest="${USER_HOME}/.orchestration"
    local py_bin="python3"
    if [ -x "${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
        py_bin="${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
    fi

    echo "================================================================================"
    echo "🚀 INSTALLING CLAUDE CODE HARNESS (GLOBAL MODE)"
    echo "   Target Dir    : ${claude_dest}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would compile agents from ${core_dir}/agents to ${claude_dest}/agents/"
        echo "  [DRY-RUN] Would symlink rules, skills, commands from ${core_dir}/ to ${claude_dest}/"
        echo "  [DRY-RUN] Would symlink master charter to ${claude_dest}/CLAUDE.md"
        echo "  [DRY-RUN] Would merge ${claude_dest}/settings.json preserving custom user config"
        echo "  [DRY-RUN] Would register vault-memory and worktree-manager in ${claude_json}"
        return 0
    fi

    mkdir -p "${claude_dest}/agents" "${claude_dest}/skills" "${claude_dest}/rules" "${claude_dest}/commands" "${claude_dest}/settings" "${claude_dest}/tools" "${claude_dest}/orchestration"

    find "${claude_dest}/rules" -xtype l -delete 2>/dev/null || true
    find "${claude_dest}/skills" -xtype l -delete 2>/dev/null || true
    find "${claude_dest}/commands" -xtype l -delete 2>/dev/null || true
    find "${claude_dest}/tools" -xtype l -delete 2>/dev/null || true

    python3 -m harness.installer.compiler \
        --core-dir "${core_dir}" \
        --runtime claude \
        --output-dir "${claude_dest}/agents"

    if [ -f "${USER_HOME}/.gemini/AGENTS.md" ]; then
        ln -sfn "${USER_HOME}/.gemini/AGENTS.md" "${claude_dest}/CLAUDE.md"
    else
        ln -sfn "${core_dir}/CHARTER.md" "${claude_dest}/CLAUDE.md"
    fi

    for r in "${core_dir}/rules"/*.md; do
        [ -f "$r" ] || continue
        ln -sfn "$r" "${claude_dest}/rules/$(basename "$r")"
    done

    for skill_path in "${core_dir}/skills"/*; do
        if [ -d "$skill_path" ]; then
            ln -sfn "$skill_path" "${claude_dest}/skills/$(basename "$skill_path")"
        fi
    done

    for c in "${core_dir}/commands"/*.md; do
        [ -f "$c" ] || continue
        ln -sfn "$c" "${claude_dest}/commands/$(basename "$c")"
    done

    for tool_path in "${canonical_repo}/scripts"/*.py "${canonical_repo}/scripts"/*.sh; do
        [ -f "$tool_path" ] || continue
        ln -sfn "$tool_path" "${claude_dest}/tools/$(basename "$tool_path")"
        chmod +x "$tool_path" 2>/dev/null || true
    done
    cp -rf "${canonical_repo}/config/orchestration/"* "${claude_dest}/orchestration/" 2>/dev/null || true

    local template_settings=("${claude_cfg}/settings/core.json")
    if [ -f "${claude_cfg}/settings/readonly.json" ]; then
        template_settings+=("${claude_cfg}/settings/readonly.json")
    fi
    python3 -m harness.installer.settings merge-claude \
        --user-settings "${claude_dest}/settings.json" \
        --template-settings "${template_settings[@]}" \
        --output "${claude_dest}/settings.json"

    python3 -m harness.installer.config_sync sync-claude \
        --claude-json "${claude_json}" \
        --repo-dir "${canonical_repo}" \
        --py-bin "${py_bin}" \
        --orch-dir "${orch_dest}"

    echo "  ✅ Installed Claude Code agents, skills, and configuration to ${claude_dest}/"
}

IS_NEW_SERVER_PASSWORD=false
CURRENT_SERVER_PASSWORD=""
CURRENT_SERVER_USERNAME=""
# Guided per-runtime config wizard + human-confirmed T3 completion gate state (Issue-#67).
RECONCILED_SERVER_USERNAME=""
RECONCILIATION_STATUS="ok"   # ok | n-a | warn | mismatch | reconciled
RECONCILIATION_NOTE=""
T3_GATE_CONFIRMED="true"     # defaults to confirmed; the gate flips it to false only when it prompts interactively and gets a negative answer

# =============================================================================
# WSL auto-login detection + OPENCODE_SERVER_USERNAME reconciliation (Issue-#67)
# The OpenCode headless server authenticates as the account systemd starts it
# under. In WSL that is the auto-login account declared by wsl.conf [user]
# default=. If OPENCODE_SERVER_USERNAME differs, the T3/Antigravity provider GUI
# "Username" must still match that WSL account. We reconcile non-destructively.
# =============================================================================

detect_wsl() {
    # Return 0 when running under the Windows Subsystem for Linux.
    if [ -n "${WSL_DISTRO_NAME:-}" ]; then
        return 0
    fi
    if [ -r "/proc/device-tree/model" ] && grep -iq microsoft /proc/device-tree/model 2>/dev/null; then
        return 0
    fi
    if [ -r "/proc/version" ] && grep -iq microsoft /proc/version 2>/dev/null; then
        return 0
    fi
    return 1
}

detect_wsl_default_user() {
    # Echo the auto-login account declared by wsl.conf [user] default= (best effort).
    # __HARNESS_WSL_CONF_PATH is a test/introspection override; production checks
    # /etc/wsl.conf first (the canonical WSL per-distro config) before any fallbacks.
    local conf_path="${__HARNESS_WSL_CONF_PATH:-}"
    if [ -z "$conf_path" ]; then
        local candidates=("/etc/wsl.conf")
        local d
        if [ -d "/mnt/c/Users" ]; then
            for d in /mnt/c/Users/*/; do
                candidates+=("${d%/}/wsl.conf")
            done
        fi
        candidates+=("/mnt/c/Windows/wsl.conf" "/mnt/c/wsl.conf")
        for d in "${candidates[@]}"; do
            if [ -r "$d" ]; then
                conf_path="$d"
                break
            fi
        done
    fi
    [ -n "$conf_path" ] && [ -r "$conf_path" ] || return 1
    # Parse only the [user] section; strip CR and comments; match the key
    # case-insensitively while preserving the original case of the value.
    awk '
        { gsub(/\r/, "") }
        /^\[user\][ \t]*$/ { sec=1; next }
        /^\[/              { sec=0 }
        sec==1 {
            line=$0
            sub(/#.*/,"",line)                       # drop trailing comment
            gsub(/^[ \t]+|[ \t]+$/,"",line)          # trim whole line
            eq=index(line,"=")
            if (eq > 0) {
                key=substr(line,1,eq-1)
                val=substr(line,eq+1)
                gsub(/^[ \t]+|[ \t]+$/,"",key)
                if (tolower(key)=="default") {
                    gsub(/^[ \t]+|[ \t]+$/,"",val)
                    if (val != "") { print val; exit }
                }
            }
        }
    ' "$conf_path" 2>/dev/null
}

reconcile_wsl_username() {
    # Resolves the OPENCODE_SERVER_USERNAME to use, setting RECONCILED_SERVER_USERNAME
    # (and RECONCILIATION_STATUS / RECONCILIATION_NOTE). UI text goes to the terminal.
    # Non-destructive when -y/--non-interactive or --dry-run: it only warns.
    local candidate="${1:-}"
    RECONCILED_SERVER_USERNAME="$candidate"

    if ! detect_wsl; then
        RECONCILIATION_STATUS="n-a"
        RECONCILIATION_NOTE=""
        return 0
    fi

    local wsl_default=""
    wsl_default="$(detect_wsl_default_user || true)"

    if [ -z "$wsl_default" ]; then
        RECONCILIATION_STATUS="warn"
        RECONCILIATION_NOTE="WSL detected but no '[user] default=' found in wsl.conf; if the headless server username differs from the T3/mobile provider Username, set OPENCODE_SERVER_USERNAME to the WSL auto-login account."
        return 0
    fi

    if [ "$wsl_default" = "$candidate" ]; then
        RECONCILIATION_STATUS="ok"
        RECONCILIATION_NOTE="WSL auto-login '${wsl_default}' already matches OPENCODE_SERVER_USERNAME."
        return 0
    fi

    # Mismatch between the WSL auto-login and the OpenCode server username.
    if [ "$NON_INTERACTIVE" = true ] || [ "$DRY_RUN" = true ]; then
        RECONCILIATION_STATUS="mismatch"
        RECONCILIATION_NOTE="WSL auto-login is '${wsl_default}' but OPENCODE_SERVER_USERNAME is '${candidate}'. Because the headless server authenticates as the WSL auto-login account, set OPENCODE_SERVER_USERNAME='${wsl_default}' (e.g. in ~/.config/opencode-backends/env) and use it as the Username in the T3/Antigravity provider GUI."
        return 0
    fi

    if [ -t 0 ]; then
        echo ""
        echo "⚠️  WSL auto-login vs OpenCode server username mismatch"
        echo "   WSL default user (auto-login) : ${wsl_default}"
        echo "   Current OPENCODE_SERVER_USERNAME: ${candidate}"
        echo "   The headless server (port 4096) authenticates as the WSL auto-login account."
        printf "  Reconcile by setting OPENCODE_SERVER_USERNAME to '%s' (recommended) [Y/n]: " "$wsl_default"
        local ans=""
        read -r ans || true
        case "$(printf '%s' "${ans:-}" | tr '[:upper:]' '[:lower:]')" in
            n|no)
                RECONCILIATION_STATUS="mismatch"
                RECONCILIATION_NOTE="Kept OPENCODE_SERVER_USERNAME='${candidate}' at user request; make sure it matches the Username in the T3/Antigravity provider GUI."
                ;;
            *)
                RECONCILIATION_STATUS="reconciled"
                RECONCILIATION_NOTE="Reconciled OPENCODE_SERVER_USERNAME to WSL auto-login '${wsl_default}'."
                candidate="$wsl_default"
                ;;
        esac
    else
        RECONCILIATION_STATUS="mismatch"
        RECONCILIATION_NOTE="Recommending OPENCODE_SERVER_USERNAME='${wsl_default}' to match WSL auto-login. Re-run ./install.sh interactively to auto-reconcile, or set it in ~/.config/opencode-backends/env and use it as the provider Username."
    fi

    RECONCILED_SERVER_USERNAME="$candidate"
}

# =============================================================================
# Guided per-runtime configuration wizard (Issue-#67)
# Interactive-only guidance shown after install, before the T3 completion gate.
# Skipped entirely in automated (-y) / dry-run paths so the bootstrap is untouched.
# =============================================================================

guided_configuration_wizard() {
    if [ "$NON_INTERACTIVE" = true ] || [ "$DRY_RUN" = true ]; then
        return 0
    fi
    if [ ! -t 0 ]; then
        return 0
    fi

    local lan_ip
    lan_ip="$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
    lan_ip="${lan_ip:-127.0.0.1}"

    local disp_user="${CURRENT_SERVER_USERNAME:-${USER:-opencode}}"
    local env_file="${USER_HOME}/.config/opencode-backends/env"
    local disp_pass=""
    if [ -f "$env_file" ]; then
        disp_pass="$(grep -E '^OPENCODE_SERVER_PASSWORD=' "$env_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)"
    fi

    local is_wsl=false
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
        is_wsl=true
    fi

    echo ""
    echo "================================================================================"
    echo "🧭 NEXT STEPS: LOG IN TO T3 CODE & VERIFY YOUR SETUP"
    echo "================================================================================"
    echo ""
    echo "Follow these 4 steps while this installer waits:"
    echo ""
    echo "  Step 1 — Open T3 Code in your browser:"
    echo "      Local (this computer) : http://localhost:3773"
    if [ "$lan_ip" != "127.0.0.1" ]; then
        echo "      LAN (other devices)   : http://${lan_ip}:3773"
    fi
    echo ""
    echo "  Step 2 — Pair / Log in to T3 Code:"
    local resolved_t3_bin=""
    for _t3_cand in "${USER_HOME}/.local/bin/t3" "${USER_HOME}/.bun/bin/t3" "$(command -v t3 2>/dev/null || true)"; do
        if [ -n "$_t3_cand" ] && [ -x "$_t3_cand" ]; then
            resolved_t3_bin="$_t3_cand"
            break
        fi
    done
    if [ -n "$resolved_t3_bin" ] && port_is_open 127.0.0.1 3773; then
        echo "      Generating a 1-hour T3 Code pairing link & QR code for you now..."
        echo ""
        "$resolved_t3_bin" pair --ttl 1h || true
        echo ""
        echo "      Scan the QR code OR paste the pairing link/code above into T3 Code."
    else
        echo "      Run 't3 pair --ttl 1h' once t3-serve is running, then scan the QR code"
        echo "      or paste the pairing link/code into T3 Code."
    fi
    if [ "$is_wsl" = true ]; then
        echo "      (To generate a new pairing code in the future, run: wsl -e bash -lc 't3 pair --ttl 1h')"
    else
        echo "      (To generate a new pairing code in the future, run: t3 pair --ttl 1h)"
    fi
    echo ""
    echo "  Step 3 — OpenCode backend credentials (used by T3 Code behind the scenes):"
    echo "      Server URL : http://127.0.0.1:4096"
    echo "      Username   : ${disp_user}"
    if [ -n "$disp_pass" ]; then
        echo "      Password   : ${disp_pass}"
    else
        echo "      Password   : see ${env_file} (OPENCODE_SERVER_PASSWORD)"
    fi
    if [ -n "${RECONCILIATION_NOTE:-}" ] && [ "${RECONCILIATION_STATUS:-n-a}" != "n-a" ]; then
        echo "      WSL Note   : ${RECONCILIATION_NOTE}"
    fi
    echo "      (If T3 Code asks for OpenCode server credentials, enter the URL, Username,"
    echo "       and Password above.)"
    echo ""
    echo "  Step 4 — Send one test message in T3 Code:"
    echo "      Start a new thread in T3 Code and send a short message (e.g. 'hello')"
    echo "      to confirm T3 Code + OpenCode reply normally."
    return 0
}

# =============================================================================
# Human-confirmed T3 verification step
# No automated live-T3 prompt/token call is made. The user logs into T3 Code,
# sends one test message, and confirms success; we only re-check ports 4096
# (OpenCode) + 3773 (T3). On confirmation it writes a ~/.bashrc launcher note.
# =============================================================================

port_is_open() {
    local host="$1" port="$2"
    curl -s -m 3 -o /dev/null "http://${host}:${port}" 2>/dev/null
}

write_launcher_snippet() {
    # Append a guarded, idempotent launcher note to an absolute bashrc path only.
    local resolved="${LAUNCHER_SNIPPET_PATH:-${USER_HOME:-$HOME}/.bashrc}"
    case "$resolved" in
        /*) ;;
        *) return 0 ;;        # only write to an absolute path
    esac
    case "$resolved" in
        /proc/*|/sys/*|/dev/*) return 0 ;;
    esac
    local marker="# >>> agent-harness launcher (Issue-#67) >>>"
    if [ -f "$resolved" ] && grep -qF "$marker" "$resolved" 2>/dev/null; then
        return 0           # already installed — leave the user's file untouched
    fi
    if [ -d "$(dirname "$resolved" 2>/dev/null)" ] 2>/dev/null; then
        {
            printf '\n'
            cat <<'EOF'
# >>> agent-harness launcher (Issue-#67) >>>
# Agent Harness readiness note. On the next WSL shell your client is ready.
# OpenCode headless server: http://$(hostname -I 2>/dev/null | awk '{print $1}'):4096
# Server Username/Password : see ~/.config/opencode-backends/env
# Launch your client:       opencode | claude | agy | t3
# <<< agent-harness launcher <<<
EOF
        } >> "$resolved" 2>/dev/null || true
    fi
}

human_confirmed_t3_gate() {
    T3_GATE_CONFIRMED="true"   # default: nothing to block (automated path / T3 off)

    # The gate is only meaningful when the T3 unified server is in scope.
    if [ "$ENABLE_T3_SERVE" = false ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ] || [ "$NON_INTERACTIVE" = true ] || [ ! -t 0 ]; then
        return 0
    fi

    # Live re-check of the two required backend ports (4096 OpenCode + 3773 T3).
    local ok_4096=false ok_3773=false
    if port_is_open 127.0.0.1 4096; then ok_4096=true; fi
    if port_is_open 127.0.0.1 3773; then ok_3773=true; fi

    echo ""
    echo "--------------------------------------------------------------------------------"
    echo "Service Readiness Check:"
    echo "  • T3 Code UI (port 3773)      : $([ "$ok_3773" = true ] && echo "READY (http://localhost:3773)" || echo "NOT reachable")"
    echo "  • OpenCode server (port 4096) : $([ "$ok_4096" = true ] && echo "READY (http://127.0.0.1:4096)" || echo "NOT reachable")"
    echo "--------------------------------------------------------------------------------"

    if [ "$ok_4096" != true ] || [ "$ok_3773" != true ]; then
        T3_GATE_CONFIRMED="false"
        echo ""
        echo "  ⚠️  One or more required services are not reachable yet:"
        [ "$ok_3773" != true ] && echo "      - Check T3 Code logs  : journalctl --user -u t3-serve.service -n 30 --no-pager"
        [ "$ok_4096" != true ] && echo "      - Check OpenCode logs : journalctl --user -u opencode-server.service -n 30 --no-pager"
        echo "      Once both services are running, re-run ./install.sh to confirm."
        return 0
    fi

    echo ""
    printf "Have you logged into T3 Code and received a reply to your test message? [y/N]: "
    local answer=""
    read -r answer || true
    case "$(printf '%s' "${answer:-}" | tr '[:upper:]' '[:lower:]')" in
        y|yes)
            write_launcher_snippet
            echo ""
            echo "================================================================================"
            echo "✅ SETUP CONFIRMED — T3 Code & OpenCode are live!"
            echo "   Launcher note added to ${LAUNCHER_SNIPPET_PATH:-${USER_HOME:-$HOME}/.bashrc}."
            echo "================================================================================"
            T3_GATE_CONFIRMED="true"
            ;;
        *)
            T3_GATE_CONFIRMED="false"
            echo ""
            echo "⏳ No problem — your services are running in the background."
            echo "   Open http://localhost:3773 and run 't3 pair --ttl 1h' whenever you're ready."
            ;;
    esac
    return 0
}

setup_backend_environment() {
    local backend_env_dir="$1"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would ensure ${backend_env_dir}/env exists for backend services"
        return 0
    fi

    mkdir -p "${backend_env_dir}"
    local env_file="${backend_env_dir}/env"

    local existing_pass=""
    local existing_user=""
    local existing_token=""

    if [ -f "$env_file" ]; then
        existing_pass="$(grep -E '^OPENCODE_SERVER_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
        existing_user="$(grep -E '^OPENCODE_SERVER_USERNAME=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
        existing_token="$(grep -E '^HF_TOKEN=' "$env_file" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r\n"'\''' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
    fi

    # HF_TOKEN handling: prompt with clear setup instructions ONLY if not already set
    local token_val="${HF_TOKEN:-${existing_token}}"
    token_val="$(printf '%s' "${token_val}" | tr -d '\r\n"'\''' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    local token_was_prompted=false
    if [ -z "$token_val" ] && [ -t 0 ] && [ "$NON_INTERACTIVE" != true ]; then
        echo ""
        echo "================================================================================"
        echo "🤗 HUGGING FACE ACCESS TOKEN (HF_TOKEN)"
        echo "================================================================================"
        echo "A free Hugging Face account + Read token lets this installer download local"
        echo "LLM weights (including gated models) faster and without rate limits."
        echo ""
        echo "  1. Create a free account (or sign in) at:"
        echo "       https://huggingface.co/join"
        echo "  2. Open your Access Tokens page:"
        echo "       https://huggingface.co/settings/tokens"
        echo "  3. Click '+ Create new token' -> select 'Read' -> give it any name"
        echo "     (e.g. 'agent-harness') -> click 'Create token'."
        echo "  4. Copy the token (starts with 'hf_...') and paste it below."
        echo ""
        read -r -p "Paste your Hugging Face token (hf_...) [or press Enter to skip]: " input_token || true
        token_val="$(printf '%s' "${input_token:-}" | tr -d '\r\n"'\''' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ -n "$token_val" ]; then
            export HF_TOKEN="$token_val"
            token_was_prompted=true
        fi
    fi

    # OPENCODE_SERVER_USERNAME handling (reconcile with WSL auto-login when applicable)
    local user_val="${OPENCODE_SERVER_USERNAME:-${existing_user}}"
    if [ -z "$user_val" ]; then
        user_val="${USER:-opencode}"
    fi
    # Non-destructive: in automated/dry-run paths reconcile_wsl_username only warns.
    reconcile_wsl_username "$user_val"
    user_val="${RECONCILED_SERVER_USERNAME:-$user_val}"
    CURRENT_SERVER_USERNAME="$user_val"

    # OPENCODE_SERVER_PASSWORD handling
    local pass_val="${OPENCODE_SERVER_PASSWORD:-${existing_pass}}"
    if [ -n "$pass_val" ]; then
        IS_NEW_SERVER_PASSWORD=false
    else
        if [ -t 0 ] && [ "$NON_INTERACTIVE" != true ]; then
            echo "A password is required for the OpenCode Remote Headless Server (port 4096)."
            read -r -s -p "Enter password [press Enter to auto-generate]: " input_pass || true
            echo ""
            if [ -n "$input_pass" ]; then
                pass_val="$input_pass"
                IS_NEW_SERVER_PASSWORD=true
            else
                pass_val="$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16)))" 2>/dev/null || openssl rand -hex 8)"
                IS_NEW_SERVER_PASSWORD=true
            fi
        else
            pass_val="$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(16)))" 2>/dev/null || openssl rand -hex 8)"
            IS_NEW_SERVER_PASSWORD=true
        fi
    fi
    CURRENT_SERVER_PASSWORD="$pass_val"

    if [ ! -f "$env_file" ]; then
        cat << EOF > "$env_file"
# OpenCode Backend Environment & Fallback Cloud API Configuration
# Gated model access token
HF_TOKEN=${token_val}
# Remote Headless Server credentials (port 4096)
OPENCODE_SERVER_USERNAME=${user_val}
OPENCODE_SERVER_PASSWORD=${pass_val}
OPENCODE_SERVER_PORT=4096
OPENCODE_SERVER_HOST=0.0.0.0
# T3 Code Unified Server credentials (port 3773)
T3_SERVE_PORT=3773
T3_SERVE_HOST=0.0.0.0
# Authoritative Orchestration Root
ORCHESTRATION_ROOT=${USER_HOME}/.orchestration
# Cloud API Fallback Keys
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
EOF
        chmod 0600 "$env_file"
        if [ -n "$token_val" ] && [ "$token_was_prompted" = true ]; then
            echo "  ✅ Saved HF_TOKEN to ${env_file}"
        fi
    else
        for var_name in ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY OPENCODE_SERVER_USERNAME OPENCODE_SERVER_PASSWORD; do
            val="${!var_name:-}"
            if [ "$var_name" = "OPENCODE_SERVER_PASSWORD" ]; then
                val="$pass_val"
            elif [ "$var_name" = "OPENCODE_SERVER_USERNAME" ]; then
                val="$user_val"
            fi
            if [ -n "$val" ]; then
                if grep -sq "^${var_name}=$" "$env_file"; then
                    sed -i "s|^${var_name}=$|${var_name}=${val}|" "$env_file"
                elif grep -sq "^${var_name}=" "$env_file"; then
                    if [ "$var_name" = "OPENCODE_SERVER_PASSWORD" ] && [ "$IS_NEW_SERVER_PASSWORD" = true ]; then
                        sed -i "s|^OPENCODE_SERVER_PASSWORD=.*|OPENCODE_SERVER_PASSWORD=${pass_val}|" "$env_file"
                    elif [ "$var_name" = "OPENCODE_SERVER_USERNAME" ] && [ -n "$user_val" ]; then
                        sed -i "s|^OPENCODE_SERVER_USERNAME=.*|OPENCODE_SERVER_USERNAME=${user_val}|" "$env_file"
                    fi
                elif ! grep -sq "^${var_name}=" "$env_file"; then
                    printf '%s=%s\n' "$var_name" "$val" >> "$env_file"
                fi
            fi
        done
        if [ -n "$token_val" ]; then
            python3 -c '
import sys
path, tok = sys.argv[1], sys.argv[2]
lines = []
with open(path, "r", encoding="utf-8", errors="ignore") as f:
    lines = f.readlines()
out = []
updated = False
for line in lines:
    if line.startswith("HF_TOKEN="):
        if not updated:
            out.append(f"HF_TOKEN={tok}\n")
            updated = True
    else:
        out.append(line)
if not updated:
    out.append(f"HF_TOKEN={tok}\n")
with open(path, "w", encoding="utf-8") as f:
    f.writelines(out)
' "$env_file" "$token_val"
            if [ "$token_was_prompted" = true ]; then
                echo "  ✅ Saved HF_TOKEN to ${env_file}"
            fi
        fi
        for fallback_var in ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY; do
            if ! grep -sq "^${fallback_var}=" "$env_file"; then
                printf '%s=\n' "$fallback_var" >> "$env_file"
            fi
        done
        if ! grep -sq "^OPENCODE_SERVER_PORT=" "$env_file"; then
            printf 'OPENCODE_SERVER_PORT=4096\n' >> "$env_file"
        fi
        if ! grep -sq "^OPENCODE_SERVER_HOST=" "$env_file"; then
            printf 'OPENCODE_SERVER_HOST=0.0.0.0\n' >> "$env_file"
        fi
        if ! grep -sq "^T3_SERVE_PORT=" "$env_file"; then
            printf 'T3_SERVE_PORT=3773\n' >> "$env_file"
        fi
        if ! grep -sq "^T3_SERVE_HOST=" "$env_file"; then
            printf 'T3_SERVE_HOST=0.0.0.0\n' >> "$env_file"
        fi
        if grep -sq "^ORCHESTRATION_ROOT=" "$env_file"; then
            sed -i "s|^ORCHESTRATION_ROOT=.*|ORCHESTRATION_ROOT=${USER_HOME}/.orchestration|" "$env_file"
        else
            printf 'ORCHESTRATION_ROOT=%s\n' "${USER_HOME}/.orchestration" >> "$env_file"
        fi
        chmod 0600 "$env_file"
    fi

    local primary_model="local-sglang/ornith-1.5-35b"
    local active_service="sglang-ornith-1.5-35b.service"
    local qwen27b_quant="modelopt"
    local qwen27b_path="nvidia/Qwen3.8-27B-NVFP4"
    if [ "$SGLANG_MODEL" = "qwen-3.8-nvfp4" ] || [ "$SGLANG_MODEL" = "qwen3.8" ] || [ "$SGLANG_MODEL" = "qwen3.8-27b" ] || [ "$SGLANG_MODEL" = "27b-nvfp4" ]; then
        primary_model="local-sglang/qwen3.8-27b"
        active_service="sglang-qwen3.8-27b.service"
        qwen27b_quant="modelopt"
        qwen27b_path="nvidia/Qwen3.8-27B-NVFP4"
    elif [ "$SGLANG_MODEL" = "qwen-3.8-q6" ] || [ "$SGLANG_MODEL" = "27b-q6" ]; then
        primary_model="local-sglang/qwen3.8-27b"
        active_service="sglang-qwen3.8-27b.service"
        qwen27b_quant="gguf"
        qwen27b_path="Qwen/Qwen3.8-27B-Instruct-GGUF/qwen3.8-27b-instruct-q6_k.gguf"
    elif [ "$SGLANG_MODEL" = "ornith-9b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-9b" ]; then
        primary_model="local-sglang/ornith-1.5-9b"
        active_service="sglang-ornith-1.5-9b.service"
    elif [ "$SGLANG_MODEL" = "ornith-35b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-35b" ]; then
        primary_model="local-sglang/ornith-1.5-35b"
        active_service="sglang-ornith-1.5-35b.service"
    fi

    local qwen27b_kv_dtype="fp8_e4m3"
    if [ "$qwen27b_quant" = "gguf" ]; then
        qwen27b_kv_dtype="auto"
    fi

    local sglang_vars=(
        "SGLANG_SERVICE=${active_service}"
        "SGLANG_PRIMARY_MODEL=${primary_model}"
        "SGLANG_BACKEND_PORT=30001"
        "SGLANG_27B_MODEL_PATH=${qwen27b_path}"
        "SGLANG_27B_SERVED_MODEL_NAME=qwen3.8-27b"
        "SGLANG_27B_QUANTIZATION=${qwen27b_quant}"
        "SGLANG_27B_KV_CACHE_DTYPE=${qwen27b_kv_dtype}"
        "SGLANG_27B_MEM_FRACTION=0.88"
        "SGLANG_27B_CONTEXT_LENGTH=262144"
        "SGLANG_27B_CHUNKED_PREFILL=2048"
        "SGLANG_27B_ATTENTION_BACKEND=flashinfer"
        "SGLANG_35B_CUDA_GRAPH_MAX_BS=8"
        "SGLANG_35B_PREFILL_GRAPH_ARGS="
        "SGLANG_35B_MAMBA_ARGS="
        "SGLANG_27B_CUDA_GRAPH_MAX_BS=8"
        "SGLANG_27B_PREFILL_GRAPH_ARGS="
        "SGLANG_27B_TORCH_COMPILE="
        "SGLANG_27B_SPECULATIVE_ALGO="
        "SGLANG_27B_SPECULATIVE_ARGS="
        "SGLANG_CPU_OFFLOAD_ARGS="
        "SGLANG_27B_CPU_OFFLOAD_ARGS="
        "SGLANG_9B_CONTEXT_LENGTH=262144"
        "SGLANG_9B_MEM_FRACTION=0.88"
        "SGLANG_9B_CUDA_GRAPH_MAX_BS=8"
        "SGLANG_9B_PREFILL_GRAPH_ARGS="
        "SGLANG_9B_CPU_OFFLOAD_ARGS="
        "SGLANG_9B_MAMBA_ARGS="
        "SGLANG_27B_MAMBA_ARGS="
    )

    for kv in "${sglang_vars[@]}"; do
        var_name="${kv%%=*}"
        val="${kv#*=}"
        if [[ "$val" =~ [[:space:]] ]] && [[ ! "$val" =~ ^\".*\"$ ]]; then
            val="\"${val}\""
        fi
        if grep -sq "^${var_name}=" "$env_file"; then
            sed -i "s|^${var_name}=.*|${var_name}=${val}|" "$env_file"
        else
            printf '%s=%s\n' "$var_name" "$val" >> "$env_file"
        fi
    done
    chmod 0600 "$env_file"

    local canonical_repo="$(resolve_canonical_repo_dir)"
    for venv_candidate in "${STACK_DIR}/venv" "${backend_env_dir}/venv"; do
        if [ -d "$venv_candidate" ]; then
            for sp in "${venv_candidate}"/lib/python*/site-packages; do
                if [ -d "$sp" ]; then
                    printf '%s\n' "${canonical_repo}" > "${sp}/agent_harness.pth"
                    echo "  🔗 Linked agent-harness into SGLang venv: ${sp}/agent_harness.pth"
                fi
            done
        fi
    done
}

verify_or_acquire_model_weights() {
    local target_model="$1"
    local backend_env_dir="$2"

    echo "================================================================================"
    echo "🧠 VERIFYING MODEL WEIGHTS & CACHE"
    echo "   Target Model  : ${target_model}"
    echo "   Download Opt  : ${DOWNLOAD_MODELS}"
    echo "================================================================================"

    if [ "$WITH_BACKENDS" != true ]; then
        echo "  ℹ️  Model weights verification skipped (--no-backends)."
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would verify model weights for ${target_model} in Hugging Face hub cache"
        return 0
    fi

    local cache_hub=""
    if [ -n "${HF_HUB_CACHE:-}" ]; then
        cache_hub="${HF_HUB_CACHE}"
    elif [ -n "${HF_HOME:-}" ]; then
        if [[ "${HF_HOME}" == */hub ]]; then
            cache_hub="${HF_HOME}"
        else
            cache_hub="${HF_HOME}/hub"
        fi
    else
        cache_hub="${USER_HOME}/.cache/huggingface/hub"
    fi

    local hf_model_dir="models--${target_model//\//--}"
    local model_path_dir="${cache_hub}/${hf_model_dir}"

    local weights_found=false
    if [ -d "${model_path_dir}/snapshots" ]; then
        for snap in "${model_path_dir}/snapshots/"*; do
            if [ -d "$snap" ]; then
                if [ -f "${snap}/.sync_complete" ] || compgen -G "${snap}/*.safetensors" > /dev/null 2>&1 || compgen -G "${snap}/*.bin" > /dev/null 2>&1; then
                    weights_found=true
                    break
                fi
            fi
        done
    fi

    if [ "$weights_found" = true ]; then
        echo "  ✅ Model weights verified in local cache: ${target_model}"
        return 0
    fi

    echo "  ⚠️  Model weights NOT found in local cache for: ${target_model}"

    if [ "$DOWNLOAD_MODELS" = true ]; then
        local hf_cli=""
        local hf_cli_label="hf"
        if [ -x "${STACK_DIR}/venv/bin/hf" ]; then
            hf_cli="${STACK_DIR}/venv/bin/hf"
        elif command -v hf >/dev/null 2>&1; then
            hf_cli="$(command -v hf)"
        elif [ -x "${STACK_DIR}/venv/bin/huggingface-cli" ]; then
            hf_cli="${STACK_DIR}/venv/bin/huggingface-cli"
            hf_cli_label="huggingface-cli"
        elif command -v huggingface-cli >/dev/null 2>&1; then
            hf_cli="$(command -v huggingface-cli)"
            hf_cli_label="huggingface-cli"
        fi

        local hf_token_val="${HF_TOKEN:-}"
        if [ -z "$hf_token_val" ] && [ -f "${backend_env_dir}/env" ]; then
            hf_token_val="$(grep -E '^HF_TOKEN=' "${backend_env_dir}/env" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '\r\n"'\''' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)"
        fi

        if [ -n "$hf_cli" ]; then
            echo "  ⬇️  Initiating automatic download via ${hf_cli_label} for ${target_model}..."
            if [ -n "$hf_token_val" ]; then
                if HF_TOKEN="${hf_token_val}" "${hf_cli}" download "${target_model}"; then
                    echo "  ✅ Model weights acquired successfully for ${target_model}"
                    return 0
                else
                    echo "  ⚠️  ${hf_cli_label} download encountered an issue."
                fi
            else
                if "${hf_cli}" download "${target_model}"; then
                    echo "  ✅ Model weights acquired successfully for ${target_model}"
                    return 0
                else
                    echo "  ⚠️  ${hf_cli_label} download encountered an issue."
                fi
            fi
        else
            echo "  ℹ️  Hugging Face CLI (hf) not found in backend venv or system PATH."
        fi
    fi

    # Print clear manual instructions if not downloaded or opt-out
    echo ""
    echo "  📋 Manual Model Acquisition Instructions:"
    echo "     1. Ensure you have access to: https://huggingface.co/${target_model}"
    echo "     2. Run the following command to download model weights:"
    echo "        hf download ${target_model}"
    echo "        (or set HF_TOKEN in ~/.config/opencode-backends/env and re-run with --download-models)"
    echo ""
}

render_reboot_box() {
    local cmd="${1:-./install.sh}"
    python3 -c '
import sys, unicodedata

def display_width(s):
    w = 0
    for ch in s:
        if ch == "\ufe0f":
            continue
        eaw = unicodedata.east_asian_width(ch)
        if eaw in ("W", "F") or ch in ("\u26a0", "\U0001f680"):
            w += 2
        elif unicodedata.category(ch).startswith("M"):
            pass
        else:
            w += 1
    return w

def make_line(content):
    cw = display_width(content)
    padding = max(0, 72 - cw)
    return f"│{content}" + (" " * padding) + "│"

cmd = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "./install.sh"
print("┌" + "─" * 72 + "┐")
print(make_line(" ⚠️  REBOOT REQUIRED: NVIDIA DRIVER UPGRADE DETECTED"))
print("├" + "─" * 72 + "┤")
print(make_line(" Your system NVIDIA driver was upgraded and requires a reboot to load."))
print(make_line(""))
print(make_line(" 1. Reboot your system:"))
print(make_line("    sudo reboot"))
print(make_line(""))
print(make_line(" 2. After reboot, resume installation with:"))
prefix = "    "
max_w = 68
if display_width(cmd) <= max_w:
    print(make_line(prefix + cmd))
else:
    words = cmd.split(" ")
    current = prefix
    for word in words:
        if display_width(current + (" " if current != prefix else "") + word) <= 71:
            current += (" " if current != prefix else "") + word
        else:
            print(make_line(current))
            current = prefix + word
    if current.strip():
        print(make_line(current))
print("└" + "─" * 72 + "┘")
' "$cmd"
}

print_next_step_box() {
    local cmd="${1:-opencode}"
    python3 -c '
import sys, unicodedata

def display_width(s):
    w = 0
    for ch in s:
        if ch == "\ufe0f":
            continue
        eaw = unicodedata.east_asian_width(ch)
        if eaw in ("W", "F") or ch in ("\u26a0", "\U0001f680"):
            w += 2
        elif unicodedata.category(ch).startswith("M"):
            pass
        else:
            w += 1
    return w

def make_line(content):
    cw = display_width(content)
    padding = max(0, 72 - cw)
    return f"│{content}" + (" " * padding) + "│"

cmd = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else "opencode"
print("┌" + "─" * 72 + "┐")
print(make_line(""))
print(make_line("   🚀 IMMEDIATE NEXT STEP: RUN THIS COMMAND IN YOUR TERMINAL:"))
print(make_line(""))
print(make_line(f"                   {cmd}"))
print(make_line(""))
print("└" + "─" * 72 + "┘")
' "$cmd"
}

print_completion_summary() {
    local lan_ip
    lan_ip="$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")"
    lan_ip="${lan_ip:-127.0.0.1}"

    local server_svc_status="⚪ installed"
    local sglang_svc_status="⚪ installed"
    local t3_svc_status="⚪ installed"
    local svc_name="${PROBED_SERVICE_NAME:-sglang-ornith-1.5-35b.service}"

    local t3_bin=""
    for p in "${USER_HOME}/.bun/bin/t3" "${USER_HOME}/.local/bin/t3" /usr/local/bin/t3 /usr/bin/t3; do
        if [ -x "$p" ]; then
            t3_bin="$p"
            break
        fi
    done
    if [ -z "$t3_bin" ]; then
        t3_bin="$(command -v t3 2>/dev/null || true)"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl --user is-active --quiet opencode-server.service 2>/dev/null; then
            server_svc_status="🟢 running"
        elif systemctl --user is-enabled --quiet opencode-server.service 2>/dev/null; then
            server_svc_status="🟡 enabled"
        fi

        if [ -n "${SGLANG_LOCAL_UNSUPPORTED_REASON:-}" ]; then
            sglang_svc_status="⚪ skipped (GPU unsupported: ${SGLANG_LOCAL_UNSUPPORTED_REASON})"
        elif systemctl --user is-active --quiet "$svc_name" 2>/dev/null; then
            sglang_svc_status="🟢 running"
        elif systemctl --user is-enabled --quiet "$svc_name" 2>/dev/null; then
            sglang_svc_status="🟡 enabled"
        fi

        if [ "$ENABLE_T3_SERVE" != true ]; then
            t3_svc_status="⚪ disabled (--no-t3)"
        elif systemctl --user is-active --quiet t3-serve.service 2>/dev/null; then
            t3_svc_status="🟢 running"
        elif systemctl --user is-enabled --quiet t3-serve.service 2>/dev/null; then
            t3_svc_status="🟡 enabled"
        fi
    fi

    local pass_display=""
    if [ "$IS_NEW_SERVER_PASSWORD" = true ]; then
        pass_display="${CURRENT_SERVER_PASSWORD} (auto-generated)"
    elif [ -n "$CURRENT_SERVER_PASSWORD" ]; then
        pass_display="******** (pre-configured in ~/.config/opencode-backends/env)"
    else
        pass_display="[none set]"
    fi
    local user_display="${CURRENT_SERVER_USERNAME:-${USER:-opencode}}"

    local probed_model_disp="${PROBED_MODEL_NAME:-ornith-1.5-35b}"
    local probed_model_path_disp="${PROBED_MODEL_PATH:-ornith-ai/Ornith-1.5-35B-A3B-NVFP4}"
    local probed_ctx_disp="${PROBED_CONTEXT_LENGTH:-262144}"
    local probed_mem_disp="${PROBED_MEM_FRACTION:-0.88}"

    echo ""
    echo "================================================================================"
    echo "📋 AGENT HARNESS DEPLOYMENT DASHBOARD"
    echo "================================================================================"
    echo "📋 Multi-Agent Harness Inventory & Configuration:"
    if [ "$MODE" = "global" ]; then
        echo "   [✓] Antigravity Plugin      : ${GEMINI_CONFIG_DIR}/plugins/agent-harness"
        echo "       Symlink Integration    : ${USER_HOME}/.agents -> ${USER_HOME}/.orchestration"
        echo "   [✓] Claude Code Harness     : ${CLAUDE_HOME_DIR}/ (settings.json, agents, rules, skills)"
        echo "   [✓] OpenCode Configuration  : ${OPENCODE_HOME_DIR}/ (opencode.json, AGENTS.md, slash commands)"
        echo "       Slash Commands Deployed : /handoff, /colbert, /reindex, /escalate"
        if [ "$WITH_BACKENDS" = true ]; then
            echo "   [✓] Systemd User Services   : ${SYSTEMD_USER_DIR}/"
            echo "       Installed Units         : opencode-server.service, opencode-model-proxy.service,"
            echo "                                 opencode-agent.slice, opencode-colbert-reindex.service,"
            echo "                                 opencode-colbert-reindex.timer, t3-serve.service, ${svc_name}"
            echo "   [✓] Probed Inference Model  : ${probed_model_disp} (${probed_model_path_disp})"
            echo "       Hardware Configuration  : Context: ${probed_ctx_disp} tokens | MemFraction: ${probed_mem_disp}"
        fi
        echo "   [✓] Knowledge Vault Memory  : ~/Vaults/home (Obsidian config registered)"
        echo "   [✓] ColBERT Semantic Engine : ~/.local/share/opencode-sglang-stack/ (FastMCP integration)"
        if [ "$WITH_FIREWALL" = true ]; then
            echo "   [✓] Network Firewall Hardening: Ports 4096 (OpenCode), 3773 (T3 Code) & 30000 (SGLang loopback) permitted"
        else
            echo "   [-] Network Firewall Hardening: Skipped (--no-firewall)"
        fi
    else
        echo "   [✓] Local Repository Orchestration (${TARGET_REPO:-.}/.orchestration)"
        echo "   [✓] Target: ${TARGET}"
    fi

    echo ""
    echo "🚀 Tool Launch Commands (Run in terminal):"
    echo "   OpenCode     : opencode"
    echo "   Claude Code  : claude"
    echo "   Antigravity  : agy"
    echo "   T3 Code      : t3 serve --host 0.0.0.0 --port 3773"
    echo "   T3 Pair      : t3 pair   (or 't3 pair --ttl 1h' when token expires)"
    echo "   Obsidian     : obsidian ~/Vaults/home"
    echo "   ColBERT      : ~/.local/share/opencode-sglang-stack/reindex_vault.sh (or '/reindex' in OpenCode)"

    if [ "$WITH_BACKENDS" = true ] && [ "$TARGET" != "agy" ] && [ "$TARGET" != "claude" ]; then
        echo ""
        echo "📡 Server Endpoints & Launch Commands:"
        echo "   OpenCode Headless Server : http://${lan_ip}:4096 [${server_svc_status}]"
        echo "                              username: ${user_display} | password: ${pass_display}"
        if [ "${RECONCILIATION_STATUS:-n-a}" != "n-a" ] && [ "${RECONCILIATION_STATUS:-n-a}" != "ok" ]; then
            echo "   ⚠️  ${RECONCILIATION_NOTE}"
        fi
        echo "   T3 Code Unified Server   : http://${lan_ip}:3773 [${t3_svc_status}]"
        echo "   SGLang Inference Server  : http://127.0.0.1:30000/v1 [${sglang_svc_status}]"
        echo "   Antigravity Remote       : agy remote-control start"
        echo "   Claude Code Server       : claude server"
    fi

    if [ "$ENABLE_T3_SERVE" != false ]; then
        echo ""
        echo "🔑 T3 Code Pairing & Remote Access (Port 3773):"
        local pair_output=""
        if [ "$DRY_RUN" != true ] && [ -n "$t3_bin" ] && [ -x "$t3_bin" ]; then
            if command -v timeout >/dev/null 2>&1; then
                pair_output="$(timeout 5 "$t3_bin" pair 2>/dev/null || true)"
            elif command -v python3 >/dev/null 2>&1; then
                pair_output="$(python3 -c 'import subprocess, sys; r = subprocess.run([sys.argv[1], "pair"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=5); print(r.stdout, end="")' "$t3_bin" 2>/dev/null || true)"
            else
                pair_output="$("$t3_bin" pair 2>/dev/null || true)"
            fi
        fi
        if echo "$pair_output" | grep -q "Token:"; then
            echo "$pair_output"
            echo ""
        fi
        echo "   Mint new 5m token & QR : t3 pair"
        echo "   Mint 1-hour token      : t3 pair --ttl 1h"
        echo "   Service logs           : journalctl --user -u t3-serve.service -n 30 --no-pager"
    fi

    local next_cmd="opencode"
    if [ "$TARGET" = "agy" ]; then
        next_cmd="agy"
    elif [ "$TARGET" = "claude" ]; then
        next_cmd="claude"
    fi

    echo ""
    print_next_step_box "$next_cmd"
    echo ""
    echo "📖 Documentation & Deep Dives:"
    echo "   Multi-Platform Remote Connections : docs/remote_connections.md"
    echo "   Obsidian Vaults & ColBERT Memory  : docs/vault_and_memory_guide.md"
    echo "   Inference & Hardware Tuning Guide : docs/inference_architecture.md"
    echo "   Full Architecture & Specification : README.md"
    echo ""
    echo "🔧 Useful Operational Commands:"
    if [ "$WITH_BACKENDS" = true ]; then
        echo "   systemctl --user status ${svc_name}"
        echo "   systemctl --user status opencode-model-proxy.service"
        echo "   systemctl --user status opencode-server.service"
        echo "   systemctl --user status t3-serve.service"
        echo "   systemctl --user status opencode-colbert-reindex.timer"
    fi
    echo "   ./install.sh --verify       (Verify harness file integrity)"
    echo "   ./install.sh --uninstall    (Safely rollback installation)"
    echo "================================================================================"
    echo ""
}

resolve_sglang_cuda_home() {
    local stack_dir="${1:-${STACK_DIR}}"
    local cand=""

    if [ "${SGLANG_SKIP_SYSTEM_CUDA:-0}" != "1" ]; then
        for cand in "${CUDA_HOME:-}" "/opt/cuda" "/usr/local/cuda"; do
            if [ -n "${cand}" ] && [ -x "${cand}/bin/nvcc" ]; then
                echo "${cand}"
                return 0
            fi
        done
    fi

    local venv_cu_dir=""
    local sp_dir=""
    for sp_dir in "${stack_dir}"/venv/lib/python*/site-packages; do
        [ -d "${sp_dir}/nvidia" ] || continue
        for cand in "${sp_dir}/nvidia/cu13" "${sp_dir}/nvidia/cu12" "${sp_dir}/nvidia/cuda_nvcc" "${sp_dir}"/nvidia/*; do
            if [ -d "${cand}" ] && [ -x "${cand}/bin/nvcc" ]; then
                venv_cu_dir="${cand}"
                break 2
            fi
        done
    done

    if [ -n "${venv_cu_dir}" ]; then
        local cuda_home_dir="${stack_dir}/cuda-home"
        local nvidia_root
        nvidia_root="$(dirname "${venv_cu_dir}")"
        rm -rf "${cuda_home_dir}" 2>/dev/null || true
        mkdir -p "${cuda_home_dir}/lib/stubs"

        ln -s "${venv_cu_dir}/bin" "${cuda_home_dir}/bin"
        if [ -d "${venv_cu_dir}/include" ]; then
            ln -s "${venv_cu_dir}/include" "${cuda_home_dir}/include"
        elif [ -d "${nvidia_root}/cuda_runtime/include" ]; then
            ln -s "${nvidia_root}/cuda_runtime/include" "${cuda_home_dir}/include"
        fi
        [ -d "${venv_cu_dir}/nvvm" ] && ln -s "${venv_cu_dir}/nvvm" "${cuda_home_dir}/nvvm"
        [ -d "${venv_cu_dir}/cccl" ] && ln -s "${venv_cu_dir}/cccl" "${cuda_home_dir}/cccl"

        local lib_src=""
        local lib_entry=""
        for lib_src in "${venv_cu_dir}/lib" "${nvidia_root}/cuda_runtime/lib"; do
            [ -d "${lib_src}" ] || continue
            for lib_entry in "${lib_src}"/*; do
                [ -e "${lib_entry}" ] || continue
                local base_name
                base_name="$(basename "${lib_entry}")"
                [ -e "${cuda_home_dir}/lib/${base_name}" ] || ln -s "${lib_entry}" "${cuda_home_dir}/lib/${base_name}"
            done
        done

        if [ ! -e "${cuda_home_dir}/lib/libcudart.so" ]; then
            local rt_lib=""
            for rt_lib in "${cuda_home_dir}"/lib/libcudart.so.*; do
                if [ -e "${rt_lib}" ]; then
                    ln -s "$(basename "${rt_lib}")" "${cuda_home_dir}/lib/libcudart.so"
                    break
                fi
            done
        fi

        local driver_lib=""
        for driver_lib in \
            /usr/lib/wsl/lib/libcuda.so \
            /usr/lib/wsl/lib/libcuda.so.1 \
            /usr/lib/x86_64-linux-gnu/libcuda.so.1 \
            /usr/lib/libcuda.so.1 \
            /usr/lib64/libcuda.so.1; do
            if [ -e "${driver_lib}" ]; then
                ln -s "${driver_lib}" "${cuda_home_dir}/lib/stubs/libcuda.so"
                break
            fi
        done

        ln -s "lib" "${cuda_home_dir}/lib64"
        echo "${cuda_home_dir}"
        return 0
    fi

    if [ -d "/usr/local/cuda" ]; then
        echo "/usr/local/cuda"
    else
        echo "/opt/cuda"
    fi
}

warmup_sglang_service() {
    if [ "$SKIP_WARMUP" = true ]; then
        echo "  ℹ️  SGLang model warmup skipped (--skip-warmup)."
        return 0
    fi

    if [ "$WITH_BACKENDS" != true ]; then
        return 0
    fi

    if [ "$TARGET" = "agy" ] || [ "$TARGET" = "claude" ]; then
        return 0
    fi

    if [ "$MODE" = "local" ] && [ "$ENABLE_SYSTEMD" != true ]; then
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would perform foreground SGLang warmup & weight verification"
        return 0
    fi

    # Auto-skip if in sandbox / test environment unless EXPLICIT_WARMUP is true
    if [ "${EXPLICIT_WARMUP:-false}" != true ]; then
        if [ "$SKIP_WARMUP" = true ]; then
            echo "  ℹ️  SGLang model warmup skipped (--skip-warmup)."
            return 0
        fi

        if { [ "${USER_HOME}" != "${HOME}" ] || [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]]; }; then
            echo "  ℹ️  SGLang model warmup skipped (isolated sandbox test environment)."
            return 0
        fi

        # Auto-skip if non-interactive
        if [ "$NON_INTERACTIVE" = true ]; then
            echo "  ℹ️  SGLang model warmup skipped (non-interactive mode)."
            return 0
        fi
    fi

    # Check if driver mismatch is already present
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi 2>&1 | grep -qi "version mismatch"; then
            render_reboot_box "${ORIGINAL_INVOCATION}" >&2
            exit 1
        fi
    fi

    local sglang_port="${SGLANG_PORT:-30000}"

    # Auto-skip if port is already active
    if curl -s -f -m 2 "http://127.0.0.1:${sglang_port}/v1/models" >/dev/null 2>&1; then
        echo "  ℹ️  SGLang inference server already active on port ${sglang_port}; skipping warmup."
        return 0
    fi

    local sglang_cmd=()
    if [ -x "${STACK_DIR}/venv/bin/sglang" ]; then
        sglang_cmd=("${STACK_DIR}/venv/bin/sglang")
    elif [ -x "${STACK_DIR}/venv/bin/python3" ]; then
        sglang_cmd=("${STACK_DIR}/venv/bin/python3" "-m" "sglang.launch_server")
    elif [ -x "${STACK_DIR}/venv/bin/python" ]; then
        sglang_cmd=("${STACK_DIR}/venv/bin/python" "-m" "sglang.launch_server")
    else
        echo "  ℹ️  SGLang binary not found in ${STACK_DIR}/venv; skipping warmup."
        return 0
    fi

    local model_path="${PROBED_MODEL_PATH:-}"
    local model_name="${PROBED_MODEL_NAME:-}"
    local ctx_len="${PROBED_CONTEXT_LENGTH:-}"
    local mem_frac="${PROBED_MEM_FRACTION:-}"

    if [ -z "$model_path" ] && [ -f "${BACKEND_DIR}/gpu_profile.json" ]; then
        model_path="$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('model_path', 'ornith-ai/Ornith-1.5-35B-A3B-NVFP4'))" "${BACKEND_DIR}/gpu_profile.json" 2>/dev/null || echo "ornith-ai/Ornith-1.5-35B-A3B-NVFP4")"
        model_name="$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('model', 'ornith-1.5-35b'))" "${BACKEND_DIR}/gpu_profile.json" 2>/dev/null || echo "ornith-1.5-35b")"
        ctx_len="$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('max_context', 262144))" "${BACKEND_DIR}/gpu_profile.json" 2>/dev/null || echo 262144)"
        mem_frac="$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('memory_fraction', 0.88))" "${BACKEND_DIR}/gpu_profile.json" 2>/dev/null || echo 0.88)"
    fi

    model_path="${model_path:-ornith-ai/Ornith-1.5-35B-A3B-NVFP4}"
    model_name="${model_name:-ornith-1.5-35b}"
    ctx_len="${ctx_len:-262144}"
    mem_frac="${mem_frac:-0.88}"

    echo ""
    echo "================================================================================"
    echo "🔄 SGLang Model Warmup & Weight Verification (Live Progress)"
    echo "================================================================================"
    echo "  Starting temporary SGLang warmup server (port ${sglang_port})..."
    echo "  Live weight loading, download progress, and CUDA allocation will display below:"
    echo ""

    local quant="${PROBED_QUANTIZATION:-}"
    if [ -z "$quant" ] && [ -f "${BACKEND_DIR}/gpu_profile.json" ]; then
        quant="$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d.get('quantization', ''))" "${BACKEND_DIR}/gpu_profile.json" 2>/dev/null || true)"
    fi
    if [ -z "$quant" ] && [ -n "${SGLANG_27B_QUANTIZATION:-}" ] && [[ "$model_path" =~ Qwen3\.8-27B ]]; then
        quant="${SGLANG_27B_QUANTIZATION}"
    fi
    if [ "$quant" = "fp4" ]; then
        quant="modelopt"
    fi
    if [ "$quant" = "q6_k" ]; then
        quant="gguf"
    fi
    if [ -z "$quant" ] && [[ "$model_path" =~ \.gguf$ ]]; then
        quant="gguf"
    fi
    if [ -z "$quant" ] && [[ "$model_path" == "nvidia/Qwen3.8-27B-NVFP4" ]]; then
        quant="modelopt"
    fi

    local run_args=()
    if [[ "${sglang_cmd[*]}" =~ sglang$ ]]; then
        run_args=("serve")
    fi
    run_args+=(
        --model-path "${model_path}"
        --served-model-name "${model_name}"
        --tool-call-parser qwen3_coder
        --reasoning-parser qwen3
        --mem-fraction-static "${mem_frac}"
        --context-length "${ctx_len}"
        --chunked-prefill-size 2048
        --max-running-requests 1
        --port "${sglang_port}"
        --host 127.0.0.1
        --disable-cuda-graph
    )
    if [ -n "$quant" ]; then
        run_args+=(--quantization "${quant}")
    fi

    local warmup_kv_dtype="${SGLANG_27B_KV_CACHE_DTYPE:-}"
    if [ -z "$warmup_kv_dtype" ] && { [[ "$model_path" =~ Qwen3\.8-27B-NVFP4 ]] || [[ "$model_path" == "nvidia/Qwen3.8-27B-NVFP4" ]]; }; then
        warmup_kv_dtype="nvfp4"
    fi
    if [ -n "$warmup_kv_dtype" ]; then
        run_args+=(--kv-cache-dtype "${warmup_kv_dtype}")
    fi

    local resolved_warmup_cuda_home=""
    resolved_warmup_cuda_home="$(resolve_sglang_cuda_home "${STACK_DIR}" 2>/dev/null || true)"
    local warmup_alloc_conf="expandable_segments:True"
    if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
        warmup_alloc_conf="expandable_segments:False"
    fi

    (
        export PYTORCH_CUDA_ALLOC_CONF="${warmup_alloc_conf}"
        export NVCC_PREPEND_FLAGS="${NVCC_PREPEND_FLAGS:--DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK}"
        export FLASHINFER_EXTRA_CUDAFLAGS="${FLASHINFER_EXTRA_CUDAFLAGS:--DCCCL_DISABLE_CTK_COMPATIBILITY_CHECK}"
        [ -d "${STACK_DIR}/venv/bin" ] && export PATH="${STACK_DIR}/venv/bin:$PATH"
        if [ -n "${resolved_warmup_cuda_home}" ] && [ -d "${resolved_warmup_cuda_home}" ]; then
            export CUDA_HOME="${resolved_warmup_cuda_home}"
            [ -d "${resolved_warmup_cuda_home}/bin" ] && export PATH="${resolved_warmup_cuda_home}/bin:$PATH"
        fi
        if [ -f "${BACKEND_DIR}/env" ]; then
            set -a
            . "${BACKEND_DIR}/env"
            set +a
        fi
        exec "${sglang_cmd[@]}" "${run_args[@]}"
    ) &
    local warmup_pid=$!

    local warmup_success=false
    local elapsed=0
    local timeout="${SGLANG_WARMUP_TIMEOUT:-300}"

    while [ $elapsed -lt $timeout ]; do
        if ! kill -0 "$warmup_pid" 2>/dev/null; then
            echo "  ⚠️  SGLang warmup process exited prematurely."
            break
        fi
        if curl -s -f -m 2 "http://127.0.0.1:${sglang_port}/v1/models" >/dev/null 2>&1; then
            warmup_success=true
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ "$warmup_success" = true ]; then
        echo ""
        echo "  ✅ SGLang warmup successful: Model is loaded and healthy."
        echo "  Releasing port ${sglang_port} for background systemd service..."
        kill -15 "$warmup_pid" 2>/dev/null || true
        local stop_wait=0
        while kill -0 "$warmup_pid" 2>/dev/null && [ $stop_wait -lt 15 ]; do
            sleep 1
            stop_wait=$((stop_wait + 1))
        done
        if kill -0 "$warmup_pid" 2>/dev/null; then
            kill -9 "$warmup_pid" 2>/dev/null || true
        fi
        for _ in $(seq 1 10); do
            if ! curl -s -m 1 "http://127.0.0.1:${sglang_port}/v1/models" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        echo "  ✅ SGLang port ${sglang_port} released cleanly."
    else
        if command -v nvidia-smi >/dev/null 2>&1; then
            if nvidia-smi 2>&1 | grep -qi "version mismatch"; then
                kill -9 "$warmup_pid" 2>/dev/null || true
                render_reboot_box "${ORIGINAL_INVOCATION}" >&2
                exit 1
            fi
        fi
        echo "  ⚠️  SGLang warmup did not verify within ${timeout}s; terminating warmup process."
        kill -15 "$warmup_pid" 2>/dev/null || true
        sleep 2
        kill -9 "$warmup_pid" 2>/dev/null || true
    fi
}

resolve_opencode_binary() {
    local candidate=""
    for candidate in \
        "${USER_HOME}/.local/bin/opencode" \
        "${USER_HOME}/.opencode/bin/opencode" \
        "${USER_HOME}/.bun/bin/opencode"; do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    candidate="$(command -v opencode 2>/dev/null || true)"
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

check_local_sglang_gpu_support() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo "No NVIDIA GPU / nvidia-smi found"
        return 1
    fi
    local smi_out=""
    smi_out="$(nvidia-smi --query-gpu=name,compute_cap,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
    if [ -z "$smi_out" ]; then
        if ! nvidia-smi >/dev/null 2>&1; then
            echo "No working NVIDIA GPU detected via nvidia-smi"
            return 1
        fi
        # Minimal/mock nvidia-smi without --query-gpu output: allow proceeding
        return 0
    fi

    local check_res=""
    check_res="$(python3 -c '
import sys
lines = [l.strip() for l in sys.stdin.read().splitlines() if l.strip()]
gpus = []
for line in lines:
    parts = [p.strip() for p in line.split(",")]
    if len(parts) < 3:
        continue
    name = parts[0]
    try:
        cc = float(parts[1])
    except ValueError:
        cc = 0.0
    try:
        vram_mb = int(float(parts[2]))
    except ValueError:
        vram_mb = 0
    gpus.append((name, cc, vram_mb))

if not gpus:
    sys.exit(0)

# Accept if at least one NVIDIA GPU meets SGLang minimum: CUDA CC >= 7.5 and >= 8 GB VRAM
supported = [g for g in gpus if g[1] >= 7.5 and g[2] >= 8000]
if supported:
    sys.exit(0)

best = max(gpus, key=lambda g: (g[1], g[2]))
name, cc, vram_mb = best
vram_gb = vram_mb / 1024.0
reasons = []
if cc < 7.5:
    reasons.append(f"CUDA compute capability {cc:.1f} < 7.5 minimum")
if vram_mb < 8000:
    reasons.append(f"{vram_gb:.1f} GB VRAM < 8 GB minimum")
sep = ", "
print(f"{name} ({sep.join(reasons)})")
sys.exit(1)
' <<< "$smi_out" 2>/dev/null)"
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "${check_res:-Unsupported NVIDIA GPU for local SGLang inference}"
        return 1
    fi
    return 0
}

systemd_unit_crash_loop_reason() {
    local unit="$1"
    command -v systemctl >/dev/null 2>&1 || return 1
    local sub_state="" exec_status="" unit_result=""
    sub_state="$(systemctl --user show -p SubState --value "$unit" 2>/dev/null || true)"
    exec_status="$(systemctl --user show -p ExecMainStatus --value "$unit" 2>/dev/null || true)"
    unit_result="$(systemctl --user show -p Result --value "$unit" 2>/dev/null || true)"
    if [ "$sub_state" = "auto-restart" ]; then
        if [ "$exec_status" = "203" ]; then
            echo "SubState=auto-restart, ExecMainStatus=203/EXEC (binary missing or not executable)"
            return 0
        fi
        if [ "$unit_result" = "exit-code" ] || { [ -n "$exec_status" ] && [ "$exec_status" != "0" ]; }; then
            echo "SubState=auto-restart, Result=${unit_result:-exit-code}, ExecMainStatus=${exec_status:-unknown}"
            return 0
        fi
    fi
    return 1
}

verify_backend_healthchecks() {
    if [ "$WITH_HEALTHCHECK" != true ]; then
        echo "  ℹ️  Backend healthchecks skipped (--no-healthcheck)."
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would verify backend healthchecks (SGLang, OpenCode server, ColBERT timer)"
        return 0
    fi

    if [ "$WITH_BACKENDS" != true ]; then
        echo "  ℹ️  Backend healthchecks skipped (--no-backends)."
        return 0
    fi

    if [ "$TARGET" != "all" ] && [ "$TARGET" != "opencode" ] && [ "$TARGET" != "sglang" ]; then
        return 0
    fi

    if [ "$MODE" = "local" ] && [ "$ENABLE_SYSTEMD" != true ]; then
        return 0
    fi

    if { [ "${USER_HOME}" != "${HOME}" ] || [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\.|antigravity-tmp|/tmp[A-Za-z0-9_]+/ ]]; } && [ "${EXPLICIT_HEALTHCHECK:-false}" != true ]; then
        echo "  ℹ️  Backend healthchecks skipped (isolated sandbox test environment)."
        return 0
    fi

    echo "================================================================================"
    echo "🩺 VERIFYING BACKEND SERVICE HEALTHCHECKS"
    echo "================================================================================"

    # Check for NVIDIA driver mismatch immediately
    if command -v nvidia-smi >/dev/null 2>&1; then
        local nv_early_probe=""
        nv_early_probe="$(nvidia-smi 2>&1 || true)"
        if echo "$nv_early_probe" | grep -qi "version mismatch"; then
            render_reboot_box "${ORIGINAL_INVOCATION}" >&2
            exit 1
        fi
    fi

    local svc_name="${PROBED_SERVICE_NAME:-sglang-ornith-1.5-35b.service}"
    local health_failed=false
    local failure_reasons=()
    local is_real_systemd_host=false
    if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\.|antigravity-tmp|/tmp[A-Za-z0-9_]+/ ]]; then
        is_real_systemd_host=true
    fi

    local resolved_opencode_bin=""
    resolved_opencode_bin="$(resolve_opencode_binary 2>/dev/null || true)"

    local sglang_bin="${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/sglang"
    local sglang_local_ready=true
    local sglang_skip_reason=""
    if [ "$is_real_systemd_host" = true ]; then
        local gpu_check_msg=""
        if ! gpu_check_msg="$(check_local_sglang_gpu_support)"; then
            sglang_local_ready=false
            SGLANG_LOCAL_UNSUPPORTED_REASON="${gpu_check_msg}"
            sglang_skip_reason="GPU unsupported for local SGLang: ${gpu_check_msg}. Use a cloud or remote AI provider in T3 Code / OpenCode."
        elif [ ! -x "$sglang_bin" ]; then
            sglang_local_ready=false
            sglang_skip_reason="SGLang binary not installed at ${sglang_bin}"
        fi
    fi

    # 1. Start / enable units if systemctl is available
    if [ "$is_real_systemd_host" = true ]; then
        # Disable legacy SGLang units and mutually exclusive model units
        for _legacy_u in opencode-sglang-ornith-35b.service opencode-sglang-qwen27b.service ornith-1.5-9b-nvfp4-low-ctx.service ornith-30000.service; do
            systemctl --user disable --now "$_legacy_u" 2>/dev/null || true
        done
        if [ "${svc_name}" = "sglang-qwen3.8-27b.service" ] || [ "${svc_name}" = "opencode-sglang-qwen27b.service" ]; then
            for _legacy_u in sglang-ornith-1.5-35b.service sglang-ornith-1.5-9b.service opencode-sglang-ornith-35b.service ornith-30000.service; do
                systemctl --user disable --now "$_legacy_u" 2>/dev/null || true
            done
        elif [ "${svc_name}" = "sglang-ornith-1.5-9b.service" ]; then
            for _legacy_u in sglang-ornith-1.5-35b.service sglang-qwen3.8-27b.service opencode-sglang-qwen27b.service opencode-sglang-ornith-35b.service; do
                systemctl --user disable --now "$_legacy_u" 2>/dev/null || true
            done
        elif [ "${svc_name}" = "sglang-ornith-1.5-35b.service" ] || [ "${svc_name}" = "opencode-sglang-ornith-35b.service" ] || [ "${svc_name}" = "ornith-30000.service" ]; then
            for _legacy_u in sglang-qwen3.8-27b.service sglang-ornith-1.5-9b.service opencode-sglang-qwen27b.service; do
                systemctl --user disable --now "$_legacy_u" 2>/dev/null || true
            done
        fi
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable opencode-colbert-reindex.timer opencode-server.service opencode-model-proxy.service 2>/dev/null || true
        systemctl --user start opencode-colbert-reindex.timer opencode-server.service opencode-model-proxy.service 2>/dev/null || true

        if [ "$sglang_local_ready" = true ]; then
            systemctl --user enable "${svc_name}" 2>/dev/null || true
            if curl -sf --max-time 2 "http://127.0.0.1:${SGLANG_BACKEND_PORT:-30001}/v1/models" >/dev/null 2>&1; then
                systemctl --user start "${svc_name}" 2>/dev/null || true
            else
                systemctl --user restart "${svc_name}" 2>/dev/null || true
            fi
        else
            systemctl --user stop "${svc_name}" 2>/dev/null || true
        fi

        if [ "$ENABLE_T3_SERVE" = true ]; then
            local t3_bin_available=false
            if command -v t3 >/dev/null 2>&1 || [ -x "${USER_HOME}/.bun/bin/t3" ] || [ -x "${USER_HOME}/.local/bin/t3" ]; then
                t3_bin_available=true
            fi
            if [ "$t3_bin_available" = true ]; then
                systemctl --user enable t3-serve.service 2>/dev/null || true
                systemctl --user start t3-serve.service 2>/dev/null || true
            fi
        fi
    fi

    # 3. Poll ColBERT timer
    echo "  Checking ColBERT reindexing timer..."
    local timer_active=false
    if command -v systemctl >/dev/null 2>&1; then
        for _ in $(seq 1 "${COLBERT_TIMER_RETRIES:-5}"); do
            if systemctl --user is-active --quiet opencode-colbert-reindex.timer 2>/dev/null; then
                timer_active=true
                break
            fi
            sleep 1
        done
    fi
    if [ "$timer_active" = true ]; then
        echo "  ✅ ColBERT reindexing timer is active."
    else
        health_failed=true
        failure_reasons+=("ColBERT timer (opencode-colbert-reindex.timer) is inactive")
        echo "  ❌ ColBERT reindexing timer is inactive."
    fi

    # 4. Poll OpenCode server (systemctl and 127.0.0.1:4096)
    echo "  Checking OpenCode headless server (port 4096)..."
    local server_ok=false
    local max_server_wait="${OPENCODE_SERVER_TIMEOUT:-${OPENCODE_SERVER_RETRIES:-30}}"
    local server_elapsed=0

    while [ "$server_elapsed" -lt "$max_server_wait" ]; do
        local server_status=""
        if command -v systemctl >/dev/null 2>&1; then
            server_status="$(systemctl --user is-active opencode-server.service 2>/dev/null || true)"
        fi

        if [ "$server_status" = "failed" ]; then
            echo "  ❌ OpenCode server (opencode-server.service) status is failed; aborting wait."
            break
        fi

        local server_crash_reason=""
        server_crash_reason="$(systemd_unit_crash_loop_reason opencode-server.service 2>/dev/null || true)"
        if [ -n "$server_crash_reason" ]; then
            echo "  ❌ OpenCode server (opencode-server.service) crash-looping (${server_crash_reason}); aborting wait."
            break
        fi

        if [ "$server_status" = "active" ] || [ "$server_status" = "activating" ]; then
            echo "  [$(date +%T)] ⏳ OpenCode server starting up (elapsed: ${server_elapsed}s / max: ${max_server_wait}s)..."
        fi

        local server_out=""
        server_out="$(curl -s -m 2 -w "\n%{http_code}" "http://127.0.0.1:4096" 2>/dev/null || true)"
        local server_code="${server_out##*$'\n'}"
        local server_resp="${server_out%$'\n'*}"

        if [ "$server_code" = "200" ] || [ "$server_code" = "401" ] || \
           curl -s -f -m 2 "http://127.0.0.1:4096" >/dev/null 2>&1 || \
           echo "$server_resp" | grep -qi "opencode"; then
            server_ok=true
            break
        fi

        sleep 2
        server_elapsed=$((server_elapsed + 2))
    done

    if [ "$server_ok" = true ]; then
        echo "  ✅ OpenCode server is active and listening on port 4096."
    else
        health_failed=true
        failure_reasons+=("OpenCode server (opencode-server.service / port 4096) failed healthcheck")
        echo "  ❌ OpenCode server failed healthcheck."
    fi

    # 4b. Poll T3 Code unified server (systemctl and 127.0.0.1:3773)
    if [ "$ENABLE_T3_SERVE" = true ]; then
        local t3_bin_found=false
        if command -v t3 >/dev/null 2>&1 || [ -x "${USER_HOME}/.bun/bin/t3" ] || [ -x "${USER_HOME}/.local/bin/t3" ]; then
            t3_bin_found=true
        fi

        if [ "$t3_bin_found" != true ]; then
            echo "  ℹ️  T3 Code binary (t3) not found in PATH; t3-serve.service deployed and ready once t3 is installed"
        else
            echo "  Checking T3 Code unified server (port 3773)..."
            if [ "$is_real_systemd_host" = true ]; then
                systemctl --user enable t3-serve.service 2>/dev/null || true
                systemctl --user start t3-serve.service 2>/dev/null || true
            fi

            local t3_server_ok=false
            local max_t3_wait="${T3_SERVER_TIMEOUT:-${T3_SERVER_RETRIES:-30}}"
            local t3_elapsed=0

            while [ "$t3_elapsed" -lt "$max_t3_wait" ]; do
                local t3_status=""
                if command -v systemctl >/dev/null 2>&1; then
                    t3_status="$(systemctl --user is-active t3-serve.service 2>/dev/null || true)"
                fi

                if [ "$t3_status" = "failed" ]; then
                    echo "  ❌ T3 Code server (t3-serve.service) status is failed; aborting wait."
                    break
                fi

                local t3_crash_reason=""
                t3_crash_reason="$(systemd_unit_crash_loop_reason t3-serve.service 2>/dev/null || true)"
                if [ -n "$t3_crash_reason" ]; then
                    echo "  ❌ T3 Code server (t3-serve.service) crash-looping (${t3_crash_reason}); aborting wait."
                    break
                fi

                if [ "$t3_status" = "active" ] || [ "$t3_status" = "activating" ]; then
                    echo "  [$(date +%T)] ⏳ T3 Code server starting up (elapsed: ${t3_elapsed}s / max: ${max_t3_wait}s)..."
                fi

                local t3_out=""
                t3_out="$(curl -s -m 2 -w "\n%{http_code}" "http://127.0.0.1:3773" 2>/dev/null || true)"
                local t3_code="${t3_out##*$'\n'}"
                local t3_resp="${t3_out%$'\n'*}"

                if [ "$t3_code" = "200" ] || [ "$t3_code" = "401" ] || \
                   curl -s -f -m 2 "http://127.0.0.1:3773" >/dev/null 2>&1 || \
                   echo "$t3_resp" | grep -qi "t3"; then
                    t3_server_ok=true
                    break
                fi

                sleep 2
                t3_elapsed=$((t3_elapsed + 2))
            done

            if [ "$t3_server_ok" = true ]; then
                echo "  ✅ T3 Code unified server is active and listening on port 3773."
            else
                health_failed=true
                failure_reasons+=("T3 Code server (t3-serve.service / port 3773) failed healthcheck")
                echo "  ❌ T3 Code unified server failed healthcheck."
            fi
        fi
    fi

    # 5. Poll SGLang (systemctl and 127.0.0.1:30000/v1/models)
    local initial_sglang_status=""
    if command -v systemctl >/dev/null 2>&1; then
        initial_sglang_status="$(systemctl --user is-active "${svc_name}" 2>/dev/null || true)"
    fi
    if [ "$sglang_local_ready" != true ] && [ "$initial_sglang_status" != "active" ] && [ "$initial_sglang_status" != "failed" ]; then
        echo "  ℹ️  Skipping local SGLang healthcheck (${sglang_skip_reason}); ${svc_name} deployed and ready when local GPU inference is enabled."
    else
        echo "  Checking SGLang inference service (${svc_name} / port 30000)..."
        local sglang_ok=false
        local max_sglang_wait="${SGLANG_MAX_WAIT:-${SGLANG_HEALTHCHECK_TIMEOUT:-${SGLANG_HEALTHCHECK_RETRIES:-360}}}"
        local prefill_capture_timeout="${SGLANG_PREFILL_CAPTURE_TIMEOUT:-90}"
        local max_fallback_attempts="${SGLANG_MAX_FALLBACK_ATTEMPTS:-8}"
        local fallback_attempt=0
        local elapsed=0
        local prefill_begin_at=""
        local model_name="${PROBED_MODEL_NAME:-ornith}"

        local fallback_handler=""
        if [ -x "${STACK_DIR}/sglang_oom_handler.sh" ]; then
            fallback_handler="${STACK_DIR}/sglang_oom_handler.sh"
        elif [ -x "${SCRIPT_DIR}/scripts/sglang_oom_handler.sh" ]; then
            fallback_handler="${SCRIPT_DIR}/scripts/sglang_oom_handler.sh"
        fi

        local inv_id=""
        if command -v systemctl >/dev/null 2>&1; then
            inv_id="$(systemctl --user show -p InvocationID --value "${svc_name}" 2>/dev/null || true)"
            [ "$inv_id" = "00000000000000000000000000000000" ] && inv_id=""
        fi

        local sglang_check_url="http://127.0.0.1:30000/v1/models"
        if curl -s -m 1 "http://127.0.0.1:30000/health" 2>/dev/null | grep -q '"active_service"'; then
            sglang_check_url="http://127.0.0.1:${SGLANG_BACKEND_PORT:-30001}/v1/models"
        fi

        while [ "$elapsed" -lt "$max_sglang_wait" ]; do
            local sglang_out=""
            sglang_out="$(curl -s -m 2 -w "\n%{http_code}" "${sglang_check_url}" 2>/dev/null || true)"
            local sglang_code="${sglang_out##*$'\n'}"
            local sglang_resp="${sglang_out%$'\n'*}"

            if [ "$sglang_code" = "200" ] || echo "$sglang_resp" | grep -q '"data"' || { [ -n "$model_name" ] && echo "$sglang_resp" | grep -qi "$model_name"; }; then
                sglang_ok=true
                break
            fi

            # Track systemd InvocationID changes (e.g., if ExecStopPost watchdog restarted the unit)
            local cur_inv_id=""
            if command -v systemctl >/dev/null 2>&1; then
                cur_inv_id="$(systemctl --user show -p InvocationID --value "${svc_name}" 2>/dev/null || true)"
                [ "$cur_inv_id" = "00000000000000000000000000000000" ] && cur_inv_id=""
            fi
            if [ -n "$cur_inv_id" ] && [ -n "$inv_id" ] && [ "$cur_inv_id" != "$inv_id" ]; then
                inv_id="$cur_inv_id"
                prefill_begin_at=""
                echo "  🔄 SGLang (${svc_name}) restarted automatically; continuing startup verification..."
            elif [ -z "$inv_id" ] && [ -n "$cur_inv_id" ]; then
                inv_id="$cur_inv_id"
            fi

            # Inspect current invocation log for recoverable prefill CUDA graph / OOM / worker crashes
            local jlog=""
            if [ -n "${SGLANG_HEALTHCHECK_LOG_FILE:-}" ] && [ -r "${SGLANG_HEALTHCHECK_LOG_FILE}" ]; then
                jlog="$(tail -n 250 "${SGLANG_HEALTHCHECK_LOG_FILE}" 2>/dev/null || true)"
            elif [ -n "$inv_id" ] && command -v journalctl >/dev/null 2>&1; then
                jlog="$(journalctl --user _SYSTEMD_INVOCATION_ID="${inv_id}" -n 250 --no-pager 2>/dev/null || true)"
            fi

            local detected_fallback_mode=""
            local detected_reason=""
            if [ -n "$jlog" ] && ! printf '%s\n' "$jlog" | grep -qiE 'unrecognized arguments|401 Client Error|GatedRepoError|ModuleNotFoundError|No module named'; then
                local saw_prefill_begin=false
                local saw_prefill_end=false
                if printf '%s\n' "$jlog" | grep -q 'Capture target prefill CUDA graph begin'; then
                    saw_prefill_begin=true
                fi
                if printf '%s\n' "$jlog" | grep -q 'Capture target prefill CUDA graph end'; then
                    saw_prefill_end=true
                fi

                if [ "$saw_prefill_begin" = true ] && [ "$saw_prefill_end" = false ]; then
                    if [ -z "$prefill_begin_at" ]; then
                        prefill_begin_at="$elapsed"
                    fi
                    if printf '%s\n' "$jlog" | grep -qiE 'double free or corruption|free\(\): invalid|malloc\(\):|Segmentation fault|SIGABRT|SIGSEGV|Fatal Python error|CUDA out of memory|torch\.OutOfMemoryError|RuntimeError: CUDA error|cudaError'; then
                        detected_fallback_mode="prefill"
                        detected_reason="worker crashed during prefill CUDA graph capture"
                    elif [ "$((elapsed - prefill_begin_at))" -ge "$prefill_capture_timeout" ]; then
                        detected_fallback_mode="prefill"
                        detected_reason="prefill CUDA graph capture stalled >${prefill_capture_timeout}s"
                    fi
                elif printf '%s\n' "$jlog" | grep -qiE 'CUDA out of memory|torch\.OutOfMemoryError|Not enough memory|double free or corruption|free\(\): invalid|malloc\(\):|Segmentation fault|SIGABRT|SIGSEGV|RuntimeError: CUDA error|cudaError'; then
                    detected_fallback_mode="auto"
                    detected_reason="CUDA/memory failure during startup"
                fi
            fi

            # If not yet ready, check systemd status
            local sglang_status=""
            if command -v systemctl >/dev/null 2>&1; then
                sglang_status="$(systemctl --user is-active "${svc_name}" 2>/dev/null || true)"
            fi

            local sglang_crash_reason=""
            sglang_crash_reason="$(systemd_unit_crash_loop_reason "${svc_name}" 2>/dev/null || true)"

            if [ -z "$detected_fallback_mode" ] && { [ "$sglang_status" = "failed" ] || [ -n "$sglang_crash_reason" ]; }; then
                if [ -n "$jlog" ] && printf '%s\n' "$jlog" | grep -q 'Capture target prefill CUDA graph begin' && ! printf '%s\n' "$jlog" | grep -q 'Capture target prefill CUDA graph end'; then
                    detected_fallback_mode="prefill"
                    detected_reason="unit failed during prefill CUDA graph capture"
                fi
            fi

            if [ -n "$detected_fallback_mode" ] && [ -n "$fallback_handler" ] && [ "$fallback_attempt" -lt "$max_fallback_attempts" ]; then
                local tmp_jlog=""
                tmp_jlog="$(mktemp /tmp/sglang-hc-log-XXXXXX 2>/dev/null || true)"
                if [ -n "$tmp_jlog" ]; then
                    printf '%s\n' "$jlog" > "$tmp_jlog"
                fi
                local step_out=""
                local step_rc=0
                step_out="$(HOME="${USER_HOME}" SGLANG_SERVICE="${svc_name}" OPENCODE_OOM_LOG="${tmp_jlog}" "${fallback_handler}" --fallback-step "${detected_fallback_mode}" --no-restart 2>&1)" || step_rc=$?
                [ -n "$tmp_jlog" ] && rm -f "$tmp_jlog"
                if [ "$step_rc" -eq 0 ]; then
                    fallback_attempt=$((fallback_attempt + 1))
                    echo "  ⚠️  SGLang ${detected_reason}; applying automatic fallback (${fallback_attempt}/${max_fallback_attempts}): ${step_out}"
                    if command -v systemctl >/dev/null 2>&1; then
                        systemctl --user stop "${svc_name}" 2>/dev/null || true
                        systemctl --user reset-failed "${svc_name}" 2>/dev/null || true
                        systemctl --user restart "${svc_name}" 2>/dev/null || true
                    fi
                    elapsed=0
                    prefill_begin_at=""
                    sleep 2
                    if command -v systemctl >/dev/null 2>&1; then
                        inv_id="$(systemctl --user show -p InvocationID --value "${svc_name}" 2>/dev/null || true)"
                        [ "$inv_id" = "00000000000000000000000000000000" ] && inv_id=""
                    fi
                    continue
                else
                    echo "  ❌ SGLang progressive fallback floor reached: ${step_out}"
                    break
                fi
            fi

            if [ "$sglang_status" = "failed" ]; then
                echo "  ❌ SGLang service (${svc_name}) status is failed; aborting wait."
                break
            fi

            if [ -n "$sglang_crash_reason" ]; then
                echo "  ❌ SGLang service (${svc_name}) crash-looping (${sglang_crash_reason}); aborting wait."
                break
            fi

            if [ "$sglang_status" = "active" ] || [ "$sglang_status" = "activating" ]; then
                echo "  [$(date +%T)] ⏳ SGLang is loading model weights into VRAM (elapsed: ${elapsed}s / max: ${max_sglang_wait}s)..."
            fi

            sleep 2
            elapsed=$((elapsed + 2))
        done

        if [ "$sglang_ok" = true ]; then
            echo "  ✅ SGLang inference engine is active and serving on port 30000."
            if [ -n "$fallback_handler" ]; then
                local active_tuning=""
                active_tuning="$(HOME="${USER_HOME}" SGLANG_SERVICE="${svc_name}" "${fallback_handler}" --status-all 2>/dev/null || true)"
                [ -n "$active_tuning" ] && echo "  ℹ️  Active SGLang runtime tuning: ${active_tuning}"
            fi
        else
            health_failed=true
            failure_reasons+=("SGLang inference service (${svc_name} / port 30000) failed healthcheck")
            echo "  ❌ SGLang inference engine failed healthcheck."
        fi
    fi

    if [ "$health_failed" = true ]; then
        local driver_mismatch=false
        if command -v nvidia-smi >/dev/null 2>&1; then
            local nv_probe=""
            nv_probe="$(nvidia-smi 2>&1 || true)"
            if echo "$nv_probe" | grep -qi "version mismatch"; then
                driver_mismatch=true
            fi
        fi

        if [ "$driver_mismatch" = true ]; then
            render_reboot_box "${ORIGINAL_INVOCATION}" >&2
            exit 1
        fi

        cat << 'EOF' >&2

❌ ========================================================================
❌ INSTALLATION INCOMPLETE: SERVICE HEALTHCHECK FAILED
❌ ========================================================================
One or more required backend services failed live healthchecks:
EOF
        for r in "${failure_reasons[@]}"; do
            echo "  - $r" >&2
        done

        echo "" >&2
        echo "📋 Diagnostic Information:" >&2
        if command -v systemctl >/dev/null 2>&1; then
            echo "--- Systemd User Unit Statuses ---" >&2
            systemctl --user status opencode-colbert-reindex.timer opencode-server.service opencode-model-proxy.service t3-serve.service "${svc_name}" --no-pager 2>&1 | head -n 80 >&2 || true
        fi
        if command -v journalctl >/dev/null 2>&1 && [ "$sglang_local_ready" = true ] && [ "${sglang_ok:-false}" != true ]; then
            echo "--- Recent ${svc_name} Journal ---" >&2
            journalctl --user -u "${svc_name}" -n 15 --no-pager 2>&1 >&2 || true
        fi
        echo "--- Socket Listening Status (Port 4096, 3773, 30000, 30001) ---" >&2
        if command -v ss >/dev/null 2>&1; then
            ss -tulpn 2>/dev/null | grep -E ':(4096|3773|30000|30001)\b' >&2 || echo "No process currently bound to port 4096, 3773, 30000 or 30001" >&2
        fi

        echo "" >&2
        echo "🔧 Remediation Steps:" >&2
        echo "  1. Check unit journal logs: journalctl --user -u ${svc_name} -u opencode-model-proxy.service -u opencode-server.service -u t3-serve.service -n 50" >&2
        echo "  2. Ensure model weights are downloaded (run with --download-models)" >&2
        echo "  3. Manually start services: systemctl --user start ${svc_name} opencode-model-proxy.service opencode-server.service t3-serve.service opencode-colbert-reindex.timer" >&2
        echo "  4. Re-run installer with --no-healthcheck to bypass live polling if testing in container/sandbox" >&2
        echo "=========================================================================" >&2
        exit 1
    fi

    echo "  ✅ All backend service healthchecks passed!"
    return 0
}

deploy_opencode_backend_and_units() {
    local systemd_dest="$1"
    local backend_env_dir="$2"

    if [ "$WITH_BACKENDS" != true ]; then
        echo "  ℹ️  Backend SGLang systemd units skipped (--no-backends)."
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would probe GPU hardware and deploy systemd user units to ${systemd_dest}/"
        return 0
    fi

    mkdir -p "${systemd_dest}" "${backend_env_dir}" "${STACK_DIR}"

    # Ensure backend env exists
    if [ ! -f "${backend_env_dir}/env" ]; then
        setup_backend_environment "${backend_env_dir}"
    fi

    # Deploy SGLang stack scripts to ${STACK_DIR}
    if [ -f "${SCRIPT_DIR}/scripts/sglang_oom_handler.sh" ]; then
        cp -f "${SCRIPT_DIR}/scripts/sglang_oom_handler.sh" "${STACK_DIR}/sglang_oom_handler.sh"
        chmod 0755 "${STACK_DIR}/sglang_oom_handler.sh"
    fi
    if [ -f "${SCRIPT_DIR}/scripts/reindex_vault.sh" ]; then
        cp -f "${SCRIPT_DIR}/scripts/reindex_vault.sh" "${STACK_DIR}/reindex_vault.sh"
        chmod 0755 "${STACK_DIR}/reindex_vault.sh"
    fi
    echo "  ✅ Deployed SGLang stack scripts to ${STACK_DIR}/"

    local is_sandbox_env=false
    if [ "${USER_HOME}" != "${HOME}" ] || [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\.|antigravity-tmp|/tmp[A-Za-z0-9_]+/ ]]; then
        is_sandbox_env=true
    fi

    local uv_bin=""
    _resolve_uv_bin() {
        local c=""
        for c in "${USER_HOME}/.local/bin/uv" "${USER_HOME}/.cargo/bin/uv" "$(command -v uv 2>/dev/null || true)"; do
            if [ -n "$c" ] && [ -x "$c" ]; then
                echo "$c"
                return 0
            fi
        done
        return 1
    }
    _ensure_uv_bin() {
        uv_bin="$(_resolve_uv_bin 2>/dev/null || true)"
        if [ -n "$uv_bin" ]; then
            return 0
        fi
        if [ "$is_sandbox_env" = true ] || [ "$DRY_RUN" = true ]; then
            return 1
        fi
        if command -v curl >/dev/null 2>&1; then
            echo "  📦 Installing uv (fast Python & package manager for Python 3.12 SGLang venv)..."
            curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 || true
            uv_bin="$(_resolve_uv_bin 2>/dev/null || true)"
        fi
        [ -n "$uv_bin" ]
    }

    # Check / provision venv (prefer Python 3.12 for SGLang/PyTorch wheel compatibility)
    local need_py312_recreate=false
    if [ -e "${STACK_DIR}/venv" ] && [ ! -L "${STACK_DIR}/venv" ] && [ "$is_sandbox_env" != true ]; then
        local existing_py="${STACK_DIR}/venv/bin/python3"
        [ ! -x "$existing_py" ] && [ -x "${STACK_DIR}/venv/bin/python" ] && existing_py="${STACK_DIR}/venv/bin/python"
        if [ -x "$existing_py" ]; then
            local existing_minor=""
            existing_minor="$("$existing_py" -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || true)"
            if [ -n "$existing_minor" ] && [ "$existing_minor" -ge 13 ] 2>/dev/null; then
                if ! "$existing_py" -c "import sglang" >/dev/null 2>&1; then
                    echo "  🔄 Existing venv uses Python 3.${existing_minor} (unsupported by SGLang/PyTorch wheels); upgrading venv to Python 3.12..."
                    need_py312_recreate=true
                fi
            fi
        fi
    fi

    if [ ! -e "${STACK_DIR}/venv" ] || [ "$need_py312_recreate" = true ]; then
        local sibling_found=false
        if [ "$need_py312_recreate" != true ]; then
            for sib in "${USER_HOME}/.local/share/agy-sglang-stack/venv" "${USER_HOME}/.local/share/agy-vllm-stack/venv"; do
                if [ -d "${sib}" ] && ([ -x "${sib}/bin/python" ] || [ -f "${sib}/pyvenv.cfg" ]); then
                    echo "  🔗 Linking healthy sibling backend venv from ${sib}..."
                    ln -sfn "${sib}" "${STACK_DIR}/venv"
                    sibling_found=true
                    break
                fi
            done
        fi
        if [ "$sibling_found" != true ]; then
            echo "  📦 Provisioning backend venv in ${STACK_DIR}/venv..."
            local sys_py_minor=""
            sys_py_minor="$(python3 -c 'import sys; print(sys.version_info.minor)' 2>/dev/null || echo "12")"
            if [ "$is_sandbox_env" != true ] && { [ "$need_py312_recreate" = true ] || [ "$sys_py_minor" -ge 13 ] 2>/dev/null || [ "$sys_py_minor" -lt 10 ] 2>/dev/null; }; then
                if _ensure_uv_bin; then
                    echo "  🐍 Installing standalone Python 3.12 via uv..."
                    "$uv_bin" python install 3.12 2>/dev/null || true
                    "$uv_bin" venv --clear --seed --python 3.12 "${STACK_DIR}/venv" || python3 -m venv "${STACK_DIR}/venv" 2>/dev/null || true
                else
                    python3 -m venv "${STACK_DIR}/venv" 2>/dev/null || true
                fi
            else
                uv_bin="$(_resolve_uv_bin 2>/dev/null || true)"
                if [ -n "$uv_bin" ]; then
                    "$uv_bin" venv --seed "${STACK_DIR}/venv" --python python3 2>/dev/null || python3 -m venv "${STACK_DIR}/venv" 2>/dev/null || true
                else
                    python3 -m venv "${STACK_DIR}/venv" 2>/dev/null || true
                fi
            fi
        fi
    else
        echo "  ✅ SGLang backend venv verified at ${STACK_DIR}/venv"
    fi

    local canonical_repo="$(resolve_canonical_repo_dir)"
    for venv_candidate in "${STACK_DIR}/venv" "${backend_env_dir}/venv"; do
        if [ -d "$venv_candidate" ]; then
            for sp in "${venv_candidate}"/lib/python*/site-packages; do
                if [ -d "$sp" ]; then
                    printf '%s\n' "${canonical_repo}" > "${sp}/agent_harness.pth"
                    echo "  🔗 Linked agent-harness into SGLang venv: ${sp}/agent_harness.pth"
                fi
            done
        fi
    done

    # Verify sglang import in venv and auto-heal if missing or broken (e.g., stale editable install)
    local py_exec="${STACK_DIR}/venv/bin/python3"
    if [ ! -x "${py_exec}" ] && [ -x "${STACK_DIR}/venv/bin/python" ]; then
        py_exec="${STACK_DIR}/venv/bin/python"
    fi

    if [ -x "${py_exec}" ]; then
        if ! "${py_exec}" -c "import sglang" >/dev/null 2>&1; then
            echo "  ⚠️  sglang import check failed in ${STACK_DIR}/venv. Attempting auto-heal..."
            local healed=false

            # Candidate paths for local sglang repositories (dynamically resolved to avoid static host/user leaks)
            local sglang_candidates=()
            [ -n "${SGLANG_REPO_PATH:-}" ] && sglang_candidates+=("${SGLANG_REPO_PATH}")
            local git_common=""
            git_common="$(git -C "${SCRIPT_DIR}" rev-parse --git-common-dir 2>/dev/null || true)"
            if [ -n "$git_common" ]; then
                local git_root=""
                git_root="$(cd "${SCRIPT_DIR}" && cd "${git_common}/.." 2>/dev/null && pwd || true)"
                if [ -n "$git_root" ]; then
                    sglang_candidates+=("$(dirname "${git_root}")/sglang/python")
                    sglang_candidates+=("$(dirname "${git_root}")/sglang")
                fi
            fi
            sglang_candidates+=(
                "${USER_HOME}/git/sglang/python"
                "${USER_HOME}/git/sglang"
                "${USER_HOME}/src/sglang/python"
                "${USER_HOME}/sglang/python"
                "$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd)/sglang/python"
                "$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd)/sglang/python"
                "$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd)/sglang/python"
                "$(cd "${SCRIPT_DIR}/../../../.." 2>/dev/null && pwd)/sglang/python"
                "$(cd "${SCRIPT_DIR}/../../../../.." 2>/dev/null && pwd)/sglang/python"
            )

            for cand in "${sglang_candidates[@]}"; do
                if [ -d "${cand}" ] && ([ -f "${cand}/setup.py" ] || [ -f "${cand}/pyproject.toml" ]); then
                    echo "  🔍 Found local sglang repository at ${cand}. Reinstalling editable..."
                    "${py_exec}" -m pip install -e "${cand}" --no-build-isolation --no-deps >/dev/null 2>&1 || true
                    if "${py_exec}" -c "import sglang" >/dev/null 2>&1; then
                        echo "  ✅ Successfully auto-healed sglang via editable install from ${cand}"
                        healed=true
                        break
                    fi
                fi
            done

            if [ "$healed" != true ]; then
                if [ "$is_sandbox_env" = true ]; then
                    echo "  ℹ️  Skipping remote sglang package install in isolated sandbox test environment."
                else
                    local sglang_gpu_reason=""
                    if [ -z "${OVERRIDE_GPU:-}" ] && ! sglang_gpu_reason="$(check_local_sglang_gpu_support)"; then
                        SGLANG_LOCAL_UNSUPPORTED_REASON="${sglang_gpu_reason}"
                        echo "  ℹ️  Skipping local SGLang package install: ${sglang_gpu_reason}."
                        echo "      OpenCode & T3 Code will still be installed and ready to use with cloud or remote AI providers."
                    else
                        echo "  📦 Installing sglang[all]>=0.4.0 into ${STACK_DIR}/venv (first-time download may take a few minutes)..."
                        uv_bin="$(_resolve_uv_bin 2>/dev/null || true)"
                        if [ -z "$uv_bin" ]; then
                            _ensure_uv_bin || true
                        fi
                        if [ -n "$uv_bin" ]; then
                            "$uv_bin" pip install --python "${py_exec}" "sglang[all]>=0.4.0" || true
                        else
                            "${py_exec}" -m pip install "sglang[all]>=0.4.0" || true
                        fi

                        if "${py_exec}" -c "import sglang" >/dev/null 2>&1; then
                            echo "  ✅ Successfully installed sglang into ${STACK_DIR}/venv"
                            healed=true
                        fi
                    fi
                fi
            fi

            if [ "$healed" != true ] && [ -z "${SGLANG_LOCAL_UNSUPPORTED_REASON:-}" ]; then
                echo "  ⚠️  Could not auto-heal sglang in ${STACK_DIR}/venv. SGLang startup may fail."
            fi
        else
            echo "  ✅ SGLang python package verified in ${STACK_DIR}/venv"
        fi
    fi

    # 1. Run GPU probe to detect hardware profile
    local gpu_profile=""
    local mem_fraction=""
    local max_context=""
    if [ -x "${SCRIPT_DIR}/scripts/gpu_probe.sh" ]; then
        gpu_profile="$("${SCRIPT_DIR}/scripts/gpu_probe.sh" ${OVERRIDE_GPU:+--override-gpu "$OVERRIDE_GPU"} ${TARGET_CONTEXT:+--target-context "$TARGET_CONTEXT"} 2>/dev/null || echo '{"profile":"fallback","memory_fraction":0.88,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"unknown device","model":"ornith-1.5-35b","model_path":"ornith-ai/Ornith-1.5-35B-A3B-NVFP4","service":"sglang-ornith-1.5-35b.service","cpu_offload_gb":0}')"
    else
        gpu_profile='{"profile":"fallback","memory_fraction":0.88,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"unknown device","model":"ornith-1.5-35b","model_path":"ornith-ai/Ornith-1.5-35B-A3B-NVFP4","service":"sglang-ornith-1.5-35b.service","cpu_offload_gb":0}'
    fi
    echo "  Detected GPU Profile: ${gpu_profile}"
    echo "$gpu_profile" > "${backend_env_dir}/gpu_profile.json"
    mem_fraction="$(printf '%s' "$gpu_profile" | grep -oE '"memory_fraction":[0-9.]+' | grep -oE '[0-9.]+' | head -n1 || echo "0.88")"
    max_context="$(printf '%s' "$gpu_profile" | grep -oE '"max_context":[0-9]+' | grep -oE '[0-9]+' | head -n1 || echo "262144")"
    local ornith_max_context="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-35b', {}); print(m.get('max_context', d.get('max_context', 262144)))" "${gpu_profile}" 2>/dev/null || echo "${max_context}")"
    local ornith_mem_fraction="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-35b', {}); print(m.get('memory_fraction', d.get('memory_fraction', 0.88)))" "${gpu_profile}" 2>/dev/null || echo "${mem_fraction}")"
    local ornith_cpu_offload_gb="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-35b', {}); print(m.get('cpu_offload_gb', d.get('cpu_offload_gb', 0)))" "${gpu_profile}" 2>/dev/null || echo "0")"
    local ornith_mamba_cache="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-35b', {}); print(m.get('max_mamba_cache_size', 'auto'))" "${gpu_profile}" 2>/dev/null || echo "auto")"
    local ornith_cg_max_bs="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-35b', {}); print(m.get('cuda_graph_max_bs_decode', 8))" "${gpu_profile}" 2>/dev/null || echo "8")"

    local qwen27b_default_ctx="${max_context:-262144}"
    if [ "${qwen27b_default_ctx:-262144}" -gt 262144 ] 2>/dev/null; then
        qwen27b_default_ctx="262144"
    fi
    local qwen27b_max_context="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('qwen3.8-27b', {}); print(m.get('max_context', ${qwen27b_default_ctx}))" "${gpu_profile}" 2>/dev/null || echo "${qwen27b_default_ctx}")"
    local qwen27b_mem_fraction="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('qwen3.8-27b', {}); print(m.get('memory_fraction', d.get('memory_fraction', 0.88)))" "${gpu_profile}" 2>/dev/null || echo "${mem_fraction}")"
    local qwen27b_cpu_offload_gb="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('qwen3.8-27b', {}); print(m.get('cpu_offload_gb', 0))" "${gpu_profile}" 2>/dev/null || echo "0")"
    local qwen27b_mamba_cache="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('qwen3.8-27b', {}); print(m.get('max_mamba_cache_size', 'auto'))" "${gpu_profile}" 2>/dev/null || echo "auto")"
    local qwen27b_cg_max_bs="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('qwen3.8-27b', {}); print(m.get('cuda_graph_max_bs_decode', 8))" "${gpu_profile}" 2>/dev/null || echo "8")"

    local ornith9b_max_context="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-9b', {}); print(m.get('max_context', d.get('max_context', 262144)))" "${gpu_profile}" 2>/dev/null || echo "${max_context}")"
    local ornith9b_mem_fraction="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-9b', {}); print(m.get('memory_fraction', d.get('memory_fraction', 0.88)))" "${gpu_profile}" 2>/dev/null || echo "${mem_fraction}")"
    local ornith9b_cpu_offload_gb="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-9b', {}); print(m.get('cpu_offload_gb', 0))" "${gpu_profile}" 2>/dev/null || echo "0")"
    local ornith9b_mamba_cache="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-9b', {}); print(m.get('max_mamba_cache_size', 'auto'))" "${gpu_profile}" 2>/dev/null || echo "auto")"
    local ornith9b_cg_max_bs="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); m=d.get('model_sizing', {}).get('ornith-1.5-9b', {}); print(m.get('cuda_graph_max_bs_decode', 8))" "${gpu_profile}" 2>/dev/null || echo "8")"

    local is_wsl_runtime=false
    if [ "${SGLANG_FORCE_WSL_TUNING:-0}" = "1" ] || grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || [ -n "${WSL_DISTRO_NAME:-}" ]; then
        is_wsl_runtime=true
    fi
    if [ "$is_wsl_runtime" = true ]; then
        # On WSL2 GPU-PV, Windows DWM shares GPU VRAM; cap static pool to 0.82 on <=26GB GPUs
        # so CUDA graph capture and Windows desktop compositor always have headroom.
        local probed_vram_gb_val
        probed_vram_gb_val="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('vram_gb', 0))" "${gpu_profile}" 2>/dev/null || echo "0")"
        if python3 -c "import sys; v=float(sys.argv[1]); sys.exit(0 if 0 < v <= 26.0 else 1)" "${probed_vram_gb_val}" 2>/dev/null; then
            ornith_mem_fraction="$(python3 -c "import sys; print(min(float(sys.argv[1]), 0.82))" "${ornith_mem_fraction}" 2>/dev/null || echo "0.82")"
            qwen27b_mem_fraction="$(python3 -c "import sys; print(min(float(sys.argv[1]), 0.82))" "${qwen27b_mem_fraction}" 2>/dev/null || echo "0.82")"
            ornith9b_mem_fraction="$(python3 -c "import sys; print(min(float(sys.argv[1]), 0.82))" "${ornith9b_mem_fraction}" 2>/dev/null || echo "0.82")"
            mem_fraction="$(python3 -c "import sys; print(min(float(sys.argv[1]), 0.82))" "${mem_fraction}" 2>/dev/null || echo "0.82")"
        fi
    fi

    local ornith_mamba_args=""
    if [[ "${ornith_mamba_cache}" =~ ^[0-9]+$ ]]; then
        ornith_mamba_args="--max-mamba-cache-size ${ornith_mamba_cache} --mamba-radix-cache-strategy extra_buffer --mamba-ssm-dtype float32"
    fi
    local qwen27b_mamba_args=""
    if [[ "${qwen27b_mamba_cache}" =~ ^[0-9]+$ ]]; then
        qwen27b_mamba_args="--max-mamba-cache-size ${qwen27b_mamba_cache} --mamba-radix-cache-strategy extra_buffer --mamba-ssm-dtype float32"
    fi
    local ornith9b_mamba_args=""
    if [[ "${ornith9b_mamba_cache}" =~ ^[0-9]+$ ]]; then
        ornith9b_mamba_args="--max-mamba-cache-size ${ornith9b_mamba_cache} --mamba-radix-cache-strategy extra_buffer --mamba-ssm-dtype float32"
    fi

    local probed_model="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('model', 'ornith-1.5-35b'))" "${gpu_profile}" 2>/dev/null || echo "ornith-1.5-35b")"
    local probed_model_path="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('model_path', 'ornith-ai/Ornith-1.5-35B-A3B-NVFP4'))" "${gpu_profile}" 2>/dev/null || echo "ornith-ai/Ornith-1.5-35B-A3B-NVFP4")"
    local probed_cpu_offload="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('cpu_offload_gb', 0))" "${gpu_profile}" 2>/dev/null || echo 0)"
    local probed_service="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('service', 'sglang-ornith-1.5-35b.service'))" "${gpu_profile}" 2>/dev/null || echo "sglang-ornith-1.5-35b.service")"

    if [ "$SGLANG_MODEL_EXPLICIT" = true ]; then
        if [ "$SGLANG_MODEL" = "qwen-3.8-nvfp4" ] || [ "$SGLANG_MODEL" = "qwen3.8" ] || [ "$SGLANG_MODEL" = "qwen3.8-27b" ] || [ "$SGLANG_MODEL" = "27b-nvfp4" ]; then
            probed_model="qwen3.8-27b"
            probed_model_path="nvidia/Qwen3.8-27B-NVFP4"
            probed_service="sglang-qwen3.8-27b.service"
            max_context="$qwen27b_max_context"
            mem_fraction="$qwen27b_mem_fraction"
            probed_cpu_offload="$qwen27b_cpu_offload_gb"
        elif [ "$SGLANG_MODEL" = "qwen-3.8-q6" ] || [ "$SGLANG_MODEL" = "27b-q6" ]; then
            probed_model="qwen3.8-27b"
            probed_model_path="Qwen/Qwen3.8-27B-Instruct-GGUF/qwen3.8-27b-instruct-q6_k.gguf"
            probed_service="sglang-qwen3.8-27b.service"
            max_context="$qwen27b_max_context"
            mem_fraction="$qwen27b_mem_fraction"
            probed_cpu_offload="$qwen27b_cpu_offload_gb"
        elif [ "$SGLANG_MODEL" = "ornith-9b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-9b" ]; then
            probed_model="ornith-1.5-9b"
            probed_model_path="ornith-ai/Ornith-1.5-9B-NVFP4"
            probed_service="sglang-ornith-1.5-9b.service"
            max_context="$ornith9b_max_context"
            mem_fraction="$ornith9b_mem_fraction"
            probed_cpu_offload="$ornith9b_cpu_offload_gb"
        elif [ "$SGLANG_MODEL" = "ornith-35b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-35b" ]; then
            probed_model="ornith-1.5-35b"
            probed_model_path="ornith-ai/Ornith-1.5-35B-A3B-NVFP4"
            probed_service="sglang-ornith-1.5-35b.service"
            max_context="$ornith_max_context"
            mem_fraction="$ornith_mem_fraction"
            probed_cpu_offload="$ornith_cpu_offload_gb"
        fi
    fi

    local ornith_offload_args=""
    if [ "${ornith_cpu_offload_gb:-0}" -gt 0 ] 2>/dev/null; then
        ornith_offload_args="--cpu-offload-gb ${ornith_cpu_offload_gb}"
    fi
    local qwen27b_offload_args=""
    if [ "${qwen27b_cpu_offload_gb:-0}" -gt 0 ] 2>/dev/null; then
        qwen27b_offload_args="--cpu-offload-gb ${qwen27b_cpu_offload_gb}"
    fi
    local ornith9b_offload_args=""
    if [ "${ornith9b_cpu_offload_gb:-0}" -gt 0 ] 2>/dev/null; then
        ornith9b_offload_args="--cpu-offload-gb ${ornith9b_cpu_offload_gb}"
    fi

    # Update gpu_profile.json when --sglang-model explicitly overrides profile parameters
    if [ "$SGLANG_MODEL_EXPLICIT" = true ] && [ -n "$SGLANG_MODEL" ] && [ -f "${backend_env_dir}/gpu_profile.json" ]; then
        python3 -c "
import json, sys
p = sys.argv[1]
try:
    with open(p, 'r') as f:
        d = json.load(f)
except Exception:
    d = {}
d['model'] = sys.argv[2]
d['model_path'] = sys.argv[3]
d['service'] = sys.argv[4]
try:
    d['max_context'] = int(sys.argv[5])
except ValueError:
    d['max_context'] = sys.argv[5]
try:
    d['memory_fraction'] = float(sys.argv[6])
except ValueError:
    d['memory_fraction'] = sys.argv[6]
try:
    offload_gb = int(sys.argv[7])
except ValueError:
    offload_gb = 0
d['cpu_offload_gb'] = offload_gb
d['cpu_offload'] = bool(offload_gb > 0)
if offload_gb > 0:
    d['offload'] = 'cpu-offload'
with open(p, 'w') as f:
    json.dump(d, f, indent=2)
" "${backend_env_dir}/gpu_profile.json" "${probed_model}" "${probed_model_path}" "${probed_service}" "${max_context}" "${mem_fraction}" "${probed_cpu_offload}"
    fi

    PROBED_MODEL_NAME="$probed_model"
    PROBED_MODEL_PATH="$probed_model_path"
    PROBED_SERVICE_NAME="$probed_service"
    PROBED_CONTEXT_LENGTH="$max_context"
    PROBED_MEM_FRACTION="$mem_fraction"

    echo "  ✅ Probed GPU resources: Model=${probed_model}, Context=${max_context}, Service=${probed_service}"

    # Update ${backend_env_dir}/env with probed variables while preserving existing secrets and 0600 mode
    if [ -f "${backend_env_dir}/env" ]; then
        python3 -c "
import sys
path = sys.argv[1]
ornith_offload = f'\"{sys.argv[7]}\"' if ' ' in sys.argv[7] else sys.argv[7]
qwen_offload = f'\"{sys.argv[10]}\"' if ' ' in sys.argv[10] else sys.argv[10]
ornith9b_offload = f'\"{sys.argv[13]}\"' if ' ' in sys.argv[13] else sys.argv[13]
keys = {
    'PROBED_CONTEXT_LENGTH': sys.argv[2],
    'PROBED_MEM_FRACTION': sys.argv[3],
    'PROBED_MODEL': sys.argv[4],
    'PROBED_CPU_OFFLOAD_GB': sys.argv[5],
    'SGLANG_SERVICE': sys.argv[14],
    'SGLANG_PRIMARY_MODEL': f'local-sglang/{sys.argv[4]}',
    'SGLANG_CONTEXT_LENGTH': sys.argv[6],
    'SGLANG_CPU_OFFLOAD_ARGS': ornith_offload,
    'SGLANG_27B_CONTEXT_LENGTH': sys.argv[8],
    'SGLANG_27B_MEM_FRACTION': sys.argv[9],
    'SGLANG_27B_CPU_OFFLOAD_ARGS': qwen_offload,
    'SGLANG_9B_CONTEXT_LENGTH': sys.argv[11],
    'SGLANG_9B_MEM_FRACTION': sys.argv[12],
    'SGLANG_9B_CPU_OFFLOAD_ARGS': ornith9b_offload,
}
lines = []
try:
    with open(path, 'r') as f:
        lines = f.readlines()
except FileNotFoundError:
    pass

new_lines = []
seen = set()
for line in lines:
    k = line.split('=', 1)[0].strip() if '=' in line else None
    if k in keys:
        new_lines.append(f'{k}={keys[k]}\n')
        seen.add(k)
    else:
        new_lines.append(line)
for k, v in keys.items():
    if k not in seen:
        new_lines.append(f'{k}={v}\n')

with open(path, 'w') as f:
    f.writelines(new_lines)
" "${backend_env_dir}/env" "${max_context}" "${mem_fraction}" "${probed_model}" "${probed_cpu_offload}" "${ornith_max_context}" "${ornith_offload_args}" "${qwen27b_max_context}" "${qwen27b_mem_fraction}" "${qwen27b_offload_args}" "${ornith9b_max_context}" "${ornith9b_mem_fraction}" "${ornith9b_offload_args}" "${probed_service}"
        chmod 0600 "${backend_env_dir}/env"
    fi

    # Model Acquisition & Cache Verification (skip on GPUs unsupported for local SGLang)
    if [ -n "${SGLANG_LOCAL_UNSUPPORTED_REASON:-}" ]; then
        echo "  ℹ️  Skipping local model weight verification/download (${SGLANG_LOCAL_UNSUPPORTED_REASON})."
    else
        verify_or_acquire_model_weights "${probed_model_path}" "${backend_env_dir}"
    fi

    # 2. Deploy model catalog template expanded with USER_HOME
    if [ -f "${SCRIPT_DIR}/config/models/models_catalog.json" ]; then
        sed "s|__USER_HOME__|${USER_HOME}|g" "${SCRIPT_DIR}/config/models/models_catalog.json" > "${backend_env_dir}/models_catalog.json"
    fi

    # 3. Stop/disable and remove stale legacy model service files from backend_env_dir and systemd_dest
    if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]] && [ "$DRY_RUN" != true ]; then
        for _legacy_u in \
            opencode-sglang-ornith-35b.service \
            opencode-sglang-qwen27b.service \
            ornith-1.5-9b-nvfp4-low-ctx.service \
            ornith-30000.service \
            ornith-1.5-35b-a3b-nvfp4.service \
            qwen-3.8-27b-nvfp4-med-ctx.service; do
            systemctl --user disable --now "$_legacy_u" 2>/dev/null || true
        done
    fi
    if [ "$DRY_RUN" != true ]; then
        rm -f "${backend_env_dir}/context_length.state"
    fi
    for stale_dir in "${backend_env_dir}" "${systemd_dest}"; do
        rm -f "${stale_dir}"/gemma-4-*.service \
              "${stale_dir}"/llama-3.3-*.service \
              "${stale_dir}"/qwen3-32b-*.service \
              "${stale_dir}"/qwen-3.8-flash-next-*.service \
              "${stale_dir}/ornith-1.5-35b-a3b-nvfp4.service" \
              "${stale_dir}/qwen-3.8-27b-nvfp4-med-ctx.service" \
              "${stale_dir}/opencode-sglang-ornith-35b.service" \
              "${stale_dir}/opencode-sglang-qwen27b.service" \
              "${stale_dir}/ornith-1.5-9b-nvfp4-low-ctx.service" \
              "${stale_dir}/ornith-30000.service" 2>/dev/null || true
    done

    # Deploy systemd service profiles into backend_env_dir
    if compgen -G "${SCRIPT_DIR}/config/systemd/*.service" > /dev/null; then
        cp -f "${SCRIPT_DIR}"/config/systemd/*.service "${backend_env_dir}/"
    fi
    if compgen -G "${SCRIPT_DIR}/config/systemd/*.timer" > /dev/null; then
        cp -f "${SCRIPT_DIR}"/config/systemd/*.timer "${backend_env_dir}/"
    fi

    # 4. Deploy systemd user units into systemd_dest (~/.config/systemd/user)
    local units=("${SYSTEMD_UNITS[@]}")

    for u in "${units[@]}"; do
        if [ -f "${SCRIPT_DIR}/config/systemd/${u}" ] || [ -L "${SCRIPT_DIR}/config/systemd/${u}" ]; then
            if [ -L "${systemd_dest}/${u}" ] || [ -f "${systemd_dest}/${u}" ]; then
                rm -f "${systemd_dest}/${u}"
            fi
            cp -a "${SCRIPT_DIR}/config/systemd/${u}" "${systemd_dest}/${u}"
        fi
    done

    # Ensure opencode CLI is installed (required by T3 Code and opencode-server.service)
    local resolved_opencode_unit_bin=""
    resolved_opencode_unit_bin="$(resolve_opencode_binary 2>/dev/null || true)"
    if [ -z "$resolved_opencode_unit_bin" ]; then
        if [ "$is_sandbox_env" != true ] && [ "$DRY_RUN" != true ]; then
            echo "  📦 Installing opencode CLI via official installer..."
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL https://opencode.ai/install | bash || true
            fi
            resolved_opencode_unit_bin="$(resolve_opencode_binary 2>/dev/null || true)"
            if [ -n "$resolved_opencode_unit_bin" ]; then
                echo "  ✅ Installed opencode CLI: ${resolved_opencode_unit_bin}"
            else
                echo "  ⚠️  Could not auto-install opencode CLI (install manually: curl -fsSL https://opencode.ai/install | bash)"
            fi
        fi
    fi

    if [ -n "$resolved_opencode_unit_bin" ]; then
        mkdir -p "${USER_HOME}/.local/bin"
        if [ "$resolved_opencode_unit_bin" != "${USER_HOME}/.local/bin/opencode" ] && [ ! -e "${USER_HOME}/.local/bin/opencode" ]; then
            ln -sf "${resolved_opencode_unit_bin}" "${USER_HOME}/.local/bin/opencode" 2>/dev/null || true
        fi
        for dest_dir in "${systemd_dest}" "${backend_env_dir}"; do
            if [ -f "${dest_dir}/opencode-server.service" ]; then
                sed -i "s|^ExecStart=.*opencode serve|ExecStart=${resolved_opencode_unit_bin} serve|" "${dest_dir}/opencode-server.service"
            fi
        done
    fi

    # Tune Ornith 35B SGLang service with probed Ornith hardware parameters (preserving 256k context on RTX 5090+)
    for dest_dir in "${systemd_dest}" "${backend_env_dir}"; do
        if [ -n "$ornith_mem_fraction" ] && [ -n "$ornith_max_context" ] && [ -f "${dest_dir}/sglang-ornith-1.5-35b.service" ]; then
            if grep -q 'Environment="SGLANG_CONTEXT_LENGTH=' "${dest_dir}/sglang-ornith-1.5-35b.service"; then
                sed -i \
                    "s|--mem-fraction-static [0-9.]*|--mem-fraction-static ${ornith_mem_fraction}|;s|Environment=\"SGLANG_CONTEXT_LENGTH=[0-9]*\"|Environment=\"SGLANG_CONTEXT_LENGTH=${ornith_max_context}\"|"\
                    "${dest_dir}/sglang-ornith-1.5-35b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_CONTEXT_LENGTH=${ornith_max_context}\"" \
                    "${dest_dir}/sglang-ornith-1.5-35b.service"
                sed -i \
                    "s|--mem-fraction-static [0-9.]*|--mem-fraction-static ${ornith_mem_fraction}|" \
                    "${dest_dir}/sglang-ornith-1.5-35b.service"
            fi
            if grep -q 'Environment="SGLANG_CPU_OFFLOAD_ARGS=' "${dest_dir}/sglang-ornith-1.5-35b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_CPU_OFFLOAD_ARGS=[^\"]*\"|Environment=\"SGLANG_CPU_OFFLOAD_ARGS=${ornith_offload_args}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-35b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_CPU_OFFLOAD_ARGS=${ornith_offload_args}\"" \
                    "${dest_dir}/sglang-ornith-1.5-35b.service"
            fi
            if [ -n "${ornith_cg_max_bs:-}" ] && grep -q 'Environment="SGLANG_35B_CUDA_GRAPH_MAX_BS=' "${dest_dir}/sglang-ornith-1.5-35b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_35B_CUDA_GRAPH_MAX_BS=[0-9]*\"|Environment=\"SGLANG_35B_CUDA_GRAPH_MAX_BS=${ornith_cg_max_bs}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-35b.service"
            fi
            if [ -n "${ornith_mamba_args:-}" ] && grep -q 'Environment="SGLANG_35B_MAMBA_ARGS=' "${dest_dir}/sglang-ornith-1.5-35b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_35B_MAMBA_ARGS=[^\"]*\"|Environment=\"SGLANG_35B_MAMBA_ARGS=${ornith_mamba_args}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-35b.service"
            fi
            sed -i \
                "s|--context-length [0-9]*\${SGLANG_CONTEXT_LENGTH}|--context-length \${SGLANG_CONTEXT_LENGTH}|" \
                "${dest_dir}/sglang-ornith-1.5-35b.service"
        fi
    done

    for dest_dir in "${systemd_dest}" "${backend_env_dir}"; do
        if [ -n "$qwen27b_mem_fraction" ] && [ -n "$qwen27b_max_context" ] && [ -f "${dest_dir}/sglang-qwen3.8-27b.service" ]; then
            if grep -q 'Environment="SGLANG_27B_MEM_FRACTION=' "${dest_dir}/sglang-qwen3.8-27b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_27B_MEM_FRACTION=[0-9.]*\"|Environment=\"SGLANG_27B_MEM_FRACTION=${qwen27b_mem_fraction}\"|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_27B_MEM_FRACTION=${qwen27b_mem_fraction}\"" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            fi
            if grep -q 'Environment="SGLANG_27B_CONTEXT_LENGTH=' "${dest_dir}/sglang-qwen3.8-27b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_27B_CONTEXT_LENGTH=[0-9]*\"|Environment=\"SGLANG_27B_CONTEXT_LENGTH=${qwen27b_max_context}\"|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_27B_CONTEXT_LENGTH=${qwen27b_max_context}\"" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            fi
            if grep -q 'Environment="SGLANG_27B_CPU_OFFLOAD_ARGS=' "${dest_dir}/sglang-qwen3.8-27b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_27B_CPU_OFFLOAD_ARGS=[^\"]*\"|Environment=\"SGLANG_27B_CPU_OFFLOAD_ARGS=${qwen27b_offload_args}\"|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_27B_CPU_OFFLOAD_ARGS=${qwen27b_offload_args}\"" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            fi
            if [ -n "${qwen27b_cg_max_bs:-}" ] && grep -q 'Environment="SGLANG_27B_CUDA_GRAPH_MAX_BS=' "${dest_dir}/sglang-qwen3.8-27b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_27B_CUDA_GRAPH_MAX_BS=[0-9]*\"|Environment=\"SGLANG_27B_CUDA_GRAPH_MAX_BS=${qwen27b_cg_max_bs}\"|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            fi
            if [ -n "${qwen27b_mamba_args:-}" ] && grep -q 'Environment="SGLANG_27B_MAMBA_ARGS=' "${dest_dir}/sglang-qwen3.8-27b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_27B_MAMBA_ARGS=[^\"]*\"|Environment=\"SGLANG_27B_MAMBA_ARGS=${qwen27b_mamba_args}\"|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            fi
            if grep -q '\${SGLANG_27B_MEM_FRACTION}' "${dest_dir}/sglang-qwen3.8-27b.service"; then
                sed -i \
                    "s|--mem-fraction-static [0-9.]*\${SGLANG_27B_MEM_FRACTION}|--mem-fraction-static \${SGLANG_27B_MEM_FRACTION}|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            else
                sed -i \
                    "s|--mem-fraction-static [0-9.]*|--mem-fraction-static ${qwen27b_mem_fraction}|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            fi
            if grep -q '\${SGLANG_27B_CONTEXT_LENGTH}' "${dest_dir}/sglang-qwen3.8-27b.service"; then
                sed -i \
                    "s|--context-length [0-9]*\${SGLANG_27B_CONTEXT_LENGTH}|--context-length \${SGLANG_27B_CONTEXT_LENGTH}|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            else
                sed -i \
                    "s|--context-length [0-9]*|--context-length ${qwen27b_max_context}|" \
                    "${dest_dir}/sglang-qwen3.8-27b.service"
            fi
        fi
    done

    for dest_dir in "${systemd_dest}" "${backend_env_dir}"; do
        if [ -n "$ornith9b_mem_fraction" ] && [ -n "$ornith9b_max_context" ] && [ -f "${dest_dir}/sglang-ornith-1.5-9b.service" ]; then
            if grep -q 'Environment="SGLANG_9B_MEM_FRACTION=' "${dest_dir}/sglang-ornith-1.5-9b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_9B_MEM_FRACTION=[0-9.]*\"|Environment=\"SGLANG_9B_MEM_FRACTION=${ornith9b_mem_fraction}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_9B_MEM_FRACTION=${ornith9b_mem_fraction}\"" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            fi
            if grep -q 'Environment="SGLANG_9B_CONTEXT_LENGTH=' "${dest_dir}/sglang-ornith-1.5-9b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_9B_CONTEXT_LENGTH=[0-9]*\"|Environment=\"SGLANG_9B_CONTEXT_LENGTH=${ornith9b_max_context}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_9B_CONTEXT_LENGTH=${ornith9b_max_context}\"" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            fi
            if grep -q 'Environment="SGLANG_9B_CPU_OFFLOAD_ARGS=' "${dest_dir}/sglang-ornith-1.5-9b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_9B_CPU_OFFLOAD_ARGS=[^\"]*\"|Environment=\"SGLANG_9B_CPU_OFFLOAD_ARGS=${ornith9b_offload_args}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            else
                sed -i \
                    "/\\[Service\\]/a Environment=\"SGLANG_9B_CPU_OFFLOAD_ARGS=${ornith9b_offload_args}\"" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            fi
            if [ -n "${ornith9b_cg_max_bs:-}" ] && grep -q 'Environment="SGLANG_9B_CUDA_GRAPH_MAX_BS=' "${dest_dir}/sglang-ornith-1.5-9b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_9B_CUDA_GRAPH_MAX_BS=[0-9]*\"|Environment=\"SGLANG_9B_CUDA_GRAPH_MAX_BS=${ornith9b_cg_max_bs}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            fi
            if [ -n "${ornith9b_mamba_args:-}" ] && grep -q 'Environment="SGLANG_9B_MAMBA_ARGS=' "${dest_dir}/sglang-ornith-1.5-9b.service"; then
                sed -i \
                    "s|Environment=\"SGLANG_9B_MAMBA_ARGS=[^\"]*\"|Environment=\"SGLANG_9B_MAMBA_ARGS=${ornith9b_mamba_args}\"|" \
                    "${dest_dir}/sglang-ornith-1.5-9b.service"
            fi
        fi
    done

    # Wire valid CUDA_HOME (system /opt/cuda, /usr/local/cuda, or synthesized venv cuda-home) into SGLang units
    # and disable CUDA VMM expandable_segments on WSL2 GPU-PV where cuMemMap conflicts with CUDA graphs.
    local resolved_sglang_cuda_home=""
    resolved_sglang_cuda_home="$(resolve_sglang_cuda_home "${STACK_DIR}" 2>/dev/null || true)"
    for dest_dir in "${systemd_dest}" "${backend_env_dir}"; do
        local sgl_unit=""
        for sgl_unit in sglang-ornith-1.5-35b.service sglang-qwen3.8-27b.service sglang-ornith-1.5-9b.service; do
            if [ -f "${dest_dir}/${sgl_unit}" ]; then
                if [ -n "${resolved_sglang_cuda_home}" ] && grep -q '^Environment="CUDA_HOME=' "${dest_dir}/${sgl_unit}"; then
                    sed -i \
                        "s|^Environment=\"CUDA_HOME=[^\"]*\"|Environment=\"CUDA_HOME=${resolved_sglang_cuda_home}\"|" \
                        "${dest_dir}/${sgl_unit}"
                fi
                if [ "${is_wsl_runtime:-false}" = true ] && grep -q '^Environment="PYTORCH_CUDA_ALLOC_CONF=' "${dest_dir}/${sgl_unit}"; then
                    sed -i \
                        's|^Environment="PYTORCH_CUDA_ALLOC_CONF=.*"|Environment="PYTORCH_CUDA_ALLOC_CONF=expandable_segments:False"|' \
                        "${dest_dir}/${sgl_unit}"
                fi
            fi
        done
    done

    # Tune T3 Code working directory if custom path requested
    if [ -n "$T3_SERVE_WORKDIR" ]; then
        local resolved_t3_workdir="$T3_SERVE_WORKDIR"
        if [[ "$resolved_t3_workdir" == "~"* ]]; then
            resolved_t3_workdir="${USER_HOME}${resolved_t3_workdir:1}"
        elif [[ "$resolved_t3_workdir" != /* ]] && [[ "$resolved_t3_workdir" != "%"* ]]; then
            resolved_t3_workdir="$(cd "$resolved_t3_workdir" 2>/dev/null && pwd || echo "$resolved_t3_workdir")"
        fi
        for dest_dir in "${systemd_dest}" "${backend_env_dir}"; do
            if [ -f "${dest_dir}/t3-serve.service" ]; then
                if grep -q '^WorkingDirectory=' "${dest_dir}/t3-serve.service"; then
                    sed -i "s|^WorkingDirectory=.*|WorkingDirectory=${resolved_t3_workdir}|" "${dest_dir}/t3-serve.service"
                else
                    sed -i "/\\[Service\\]/a WorkingDirectory=${resolved_t3_workdir}" "${dest_dir}/t3-serve.service"
                fi
            fi
        done
    fi

    # 5. Reload systemd daemon if available (prior to enabling or starting services)
    if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]]; then
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user enable opencode-model-proxy.service 2>/dev/null || true
    fi

    # 6. Manage T3 Code (t3 serve) service activation & optional installation
    # Clean up legacy opencode-t3-serve.service if present on host
    if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]]; then
        systemctl --user disable --now opencode-t3-serve.service 2>/dev/null || true
    fi
    rm -f "${systemd_dest}/opencode-t3-serve.service" "${backend_env_dir}/opencode-t3-serve.service"

    local t3_installed=false
    if command -v t3 >/dev/null 2>&1 || [ -x "${USER_HOME}/.bun/bin/t3" ] || [ -x "${USER_HOME}/.local/bin/t3" ]; then
        t3_installed=true
    fi

    local t3_should_enable=false
    if [ "$ENABLE_T3_SERVE" = true ]; then
        t3_should_enable=true
    elif [ "$EXPLICIT_NO_T3" != true ] && [ "$t3_installed" = true ]; then
        t3_should_enable=true
    fi

    if [ "$ENABLE_T3_SERVE" = true ] && [ "$t3_installed" != true ]; then
        if [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]] && [ "$DRY_RUN" != true ]; then
            echo "  📦 Installing t3 CLI via official installer..."
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL https://t3.codes/install.sh | T3CODE_INSTALL_BIN_DIR="${USER_HOME}/.local/bin" T3CODE_HOME="${USER_HOME}/.t3" sh 2>/dev/null || true
            fi
            if command -v t3 >/dev/null 2>&1 || [ -x "${USER_HOME}/.bun/bin/t3" ] || [ -x "${USER_HOME}/.local/bin/t3" ]; then
                t3_installed=true
            fi
        fi
    fi

    if [ "$t3_should_enable" = true ]; then
        if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]] && [ "$DRY_RUN" != true ]; then
            systemctl --user enable t3-serve.service 2>/dev/null || true
            if [ "$t3_installed" = true ]; then
                echo "  🚀 Enabling and starting t3-serve.service..."
                systemctl --user start t3-serve.service 2>/dev/null || true
            else
                echo "  ℹ️  T3 Code binary (t3) not found; t3-serve.service enabled and ready once t3 is installed."
            fi
        fi
    elif [ "$EXPLICIT_NO_T3" = true ]; then
        if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]] && [ "$DRY_RUN" != true ]; then
            systemctl --user stop t3-serve.service 2>/dev/null || true
            systemctl --user disable t3-serve.service 2>/dev/null || true
        fi
    fi
    echo "  ✅ Deployed systemd user units to ${systemd_dest}/"
}

install_opencode_global() {
    local opencode_dest="${OPENCODE_HOME_DIR}"
    local legacy_launchers=("opencode-local" "opencode-architect-local" "opencode-worker-local" "opencode-reviewer-local" "opencode-sub-agent-local")
    local backend_env_dir="${BACKEND_DIR}"
    local systemd_dest="${SYSTEMD_USER_DIR}"
    local canonical_repo="$(resolve_canonical_repo_dir)"
    local core_dir="${SCRIPT_DIR}/core"
    [ -d "$core_dir" ] || core_dir="${canonical_repo}/core"
    local orch_dest="${USER_HOME}/.orchestration"
    local py_bin="python3"
    if [ -x "${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
        py_bin="${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
    fi

    echo "================================================================================"
    echo "🚀 INSTALLING OPENCODE HARNESS (GLOBAL MODE)"
    echo "   Target Dir    : ${opencode_dest}"
    echo "   Backend Dir   : ${backend_env_dir}"
    echo "   Systemd Dir   : ${systemd_dest}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        if [ "$WITH_BACKENDS" != true ]; then
            echo "  ℹ️  Backend SGLang systemd units skipped (--no-backends)."
        else
            echo "  [DRY-RUN] Would ensure ${backend_env_dir}/env exists for backend services"
            echo "  [DRY-RUN] Would probe GPU hardware via scripts/gpu_probe.sh and save to ${backend_env_dir}/gpu_profile.json"
            echo "  [DRY-RUN] Would update ${backend_env_dir}/env with PROBED_* sizing parameters"
            verify_or_acquire_model_weights "ornith-ai/Ornith-1.5-35B-A3B-NVFP4" "${backend_env_dir}"
            echo "  [DRY-RUN] Would probe GPU hardware and deploy systemd user units to ${systemd_dest}/"
        fi
        echo "  [DRY-RUN] Would prune legacy launchers in ${USER_HOME}/.local/bin/"
        echo "  [DRY-RUN] Would compile agents from ${core_dir}/agents to ${opencode_dest}/agents/"
        echo "  [DRY-RUN] Would symlink rules, skills, commands from ${core_dir}/ to ${opencode_dest}/"
        echo "  [DRY-RUN] Would configure opencode.json without AGENTS.md in instructions and without compaction/summary subagents"
        return 0
    fi

    setup_backend_environment "${backend_env_dir}"

    for legacy_launcher in "${legacy_launchers[@]}"; do
        rm -f "${USER_HOME}/.local/bin/${legacy_launcher}"
    done

    mkdir -p "${opencode_dest}/agents" "${opencode_dest}/commands" "${opencode_dest}/skills" "${opencode_dest}/tools" "${opencode_dest}/rules" "${opencode_dest}/plugins" "${opencode_dest}/themes" "${opencode_dest}/orchestration"

    find "${opencode_dest}/rules" -xtype l -delete 2>/dev/null || true
    find "${opencode_dest}/skills" -xtype l -delete 2>/dev/null || true
    find "${opencode_dest}/commands" -xtype l -delete 2>/dev/null || true
    find "${opencode_dest}/tools" -xtype l -delete 2>/dev/null || true

    rm -f "${opencode_dest}/agents/compaction.md" "${opencode_dest}/agents/summary.md"

    local model_profile_arg=()
    if [ "$SGLANG_MODEL" = "qwen-3.8-nvfp4" ] || [ "$SGLANG_MODEL" = "qwen3.8" ] || [ "$SGLANG_MODEL" = "qwen3.8-27b" ] || [ "$SGLANG_MODEL" = "27b-nvfp4" ] || [ "$SGLANG_MODEL" = "qwen-3.8-q6" ] || [ "$SGLANG_MODEL" = "27b-q6" ]; then
        model_profile_arg=(--model-profile "qwen3.8-27b")
    elif [ "$SGLANG_MODEL" = "ornith-9b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-9b" ]; then
        model_profile_arg=(--model-profile "ornith-1.5-9b")
    elif [ "$SGLANG_MODEL" = "ornith-35b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-35b" ]; then
        model_profile_arg=(--model-profile "ornith-1.5-35b")
    fi

    python3 -m harness.installer.compiler \
        --core-dir "${core_dir}" \
        --runtime opencode \
        --output-dir "${opencode_dest}/agents" \
        "${model_profile_arg[@]}"

    rm -f "${opencode_dest}/agents/compaction.md" "${opencode_dest}/agents/summary.md"

    if [ -f "${USER_HOME}/.gemini/AGENTS.md" ]; then
        ln -sfn "${USER_HOME}/.gemini/AGENTS.md" "${opencode_dest}/AGENTS.md"
    else
        ln -sfn "${core_dir}/CHARTER.md" "${opencode_dest}/AGENTS.md"
    fi

    for r in "${core_dir}/rules"/*.md; do
        [ -f "$r" ] || continue
        ln -sfn "$r" "${opencode_dest}/rules/$(basename "$r")"
    done

    for skill_path in "${core_dir}/skills"/*; do
        if [ -d "$skill_path" ]; then
            ln -sfn "$skill_path" "${opencode_dest}/skills/$(basename "$skill_path")"
        fi
    done

    for c in "${core_dir}/commands"/*.md; do
        [ -f "$c" ] || continue
        ln -sfn "$c" "${opencode_dest}/commands/$(basename "$c")"
    done

    for tool_path in "${canonical_repo}/scripts"/*.py "${canonical_repo}/scripts"/*.sh; do
        [ -f "$tool_path" ] || continue
        ln -sfn "$tool_path" "${opencode_dest}/tools/$(basename "$tool_path")"
        chmod +x "$tool_path" 2>/dev/null || true
    done

    cp -rf "${canonical_repo}/config/opencode/plugins/"* "${opencode_dest}/plugins/" 2>/dev/null || true
    cp -rf "${canonical_repo}/config/opencode/themes/"* "${opencode_dest}/themes/" 2>/dev/null || true
    cp -rf "${canonical_repo}/config/orchestration/"* "${opencode_dest}/orchestration/" 2>/dev/null || true
    cp -f "${canonical_repo}/config/opencode/tui.json" "${opencode_dest}/tui.json" 2>/dev/null || true

    if [ ! -f "${opencode_dest}/opencode.json" ]; then
        if [ -f "${SCRIPT_DIR}/config/opencode/opencode.json" ]; then
            cp -f "${SCRIPT_DIR}/config/opencode/opencode.json" "${opencode_dest}/opencode.json"
        else
            cp -f "${canonical_repo}/config/opencode/opencode.json" "${opencode_dest}/opencode.json"
        fi
    fi

    deploy_opencode_backend_and_units "${systemd_dest}" "${backend_env_dir}"

    local effective_sglang_model="${SGLANG_MODEL:-}"
    if [ "$SGLANG_MODEL_EXPLICIT" != true ] && [ -n "${PROBED_MODEL_NAME:-}" ]; then
        effective_sglang_model="${PROBED_MODEL_NAME}"
        if [ "${PROBED_MODEL_NAME}" != "ornith-1.5-35b" ]; then
            python3 -m harness.installer.compiler \
                --core-dir "${core_dir}" \
                --runtime opencode \
                --output-dir "${opencode_dest}/agents" \
                --model-profile "${PROBED_MODEL_NAME}"
            rm -f "${opencode_dest}/agents/compaction.md" "${opencode_dest}/agents/summary.md"
        fi
    fi

    if [ -x "${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
        py_bin="${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
    fi

    python3 -m harness.installer.config_sync sync-opencode \
        --opencode-json "${opencode_dest}/opencode.json" \
        --repo-dir "${canonical_repo}" \
        --py-bin "${py_bin}" \
        --orch-dir "${orch_dest}" \
        --opencode-dir "${opencode_dest}" \
        --sglang-model "${effective_sglang_model}"

    if [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]] && [ "$DRY_RUN" != true ]; then
        rm -f "${USER_HOME}/.t3/caches/opencode.json"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user try-restart opencode-server.service 2>/dev/null || true
        fi
        if command -v opencode >/dev/null 2>&1 && pgrep -u "$(id -u)" -f "opencode serve --service" >/dev/null 2>&1; then
            if command -v timeout >/dev/null 2>&1; then
                timeout 3 opencode reload >/dev/null 2>&1 || true
            else
                opencode reload >/dev/null 2>&1 || true
            fi
        fi
    fi

    echo "  ✅ Installed OpenCode 10-component hierarchy & systemd backend services to ${opencode_dest}/"
}

# --- LOCAL TARGET INSTALLERS --------------------------------------------------

install_agy_local() {
    local repo_path="$TARGET_REPO"
    local dest_orch="${repo_path}/.orchestration"
    local dest_agents="${repo_path}/.agents"
    local canonical_repo="$(resolve_canonical_repo_dir)"
    local core_dir="${SCRIPT_DIR}/core"
    [ -d "$core_dir" ] || core_dir="${canonical_repo}/core"

    echo "================================================================================"
    echo "🚀 INSTALLING AGY HARNESS (LOCAL REPOSITORY MODE)"
    echo "   Repository    : ${repo_path}"
    echo "   Orchestration : ${dest_orch}"
    echo "   Agents Link   : ${dest_agents}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would migrate legacy .agent/ to .agents/ if present"
        echo "  [DRY-RUN] Would deploy operational assets to ${dest_orch}/"
        echo "  [DRY-RUN] Would create symlink ${dest_agents} -> .orchestration"
        echo "  [DRY-RUN] Would link workspace instruction files (AGENTS.md, GEMINI.md, CLAUDE.md) when absent"
        echo "  [DRY-RUN] Ensure ${repo_path}/.gitignore ignores .agents/ and .orchestration/worktrees/"
        return 0
    fi

    # 1. Migrate legacy .agent (singular) to .agents (plural)
    if [ -d "${repo_path}/.agent" ] && [ ! -L "${repo_path}/.agent" ]; then
        echo "  ⚠️ Found legacy .agent (singular) in ${repo_path}, migrating to .agents/..."
        local bak_agent="${repo_path}/.agent.pre-harness.bak"
        if [ ! -e "$bak_agent" ]; then
            mv "${repo_path}/.agent" "$bak_agent"
            echo "  ⚠️ Backed up legacy ${repo_path}/.agent to ${bak_agent}"
        else
            rm -rf "${repo_path}/.agent"
        fi
    elif [ -L "${repo_path}/.agent" ]; then
        rm -f "${repo_path}/.agent"
    fi

    if [ "$REINSTALL" = true ] && [ -d "$dest_orch" ]; then
        rm -rf "${dest_orch}/rules" "${dest_orch}/skills" "${dest_orch}/tools" "${dest_orch}/orchestration"
    fi

    mkdir -p "${dest_orch}/rules" "${dest_orch}/skills" "${dest_orch}/tools" "${dest_orch}/handoffs" "${dest_orch}/orchestration" "${dest_orch}/memory" "${dest_orch}/worktrees" "${dest_orch}/logs" "${dest_orch}/tmp"

    find "${dest_orch}/rules" -xtype l -delete 2>/dev/null || true
    for r in "${core_dir}/rules"/*.md; do
        [ -f "$r" ] || continue
        ln -sfn "$r" "${dest_orch}/rules/$(basename "$r")"
    done

    for skill_path in "${core_dir}/skills"/*; do
        if [ -d "$skill_path" ]; then
            ln -sfn "$skill_path" "${dest_orch}/skills/$(basename "$skill_path")"
        fi
    done

    for tool_path in "${canonical_repo}/scripts"/*.py "${canonical_repo}/scripts"/*.sh; do
        [ -f "$tool_path" ] || continue
        ln -sfn "$tool_path" "${dest_orch}/tools/$(basename "$tool_path")"
        chmod +x "$tool_path" 2>/dev/null || true
    done

    cp -rf "${canonical_repo}/config/orchestration/"* "${dest_orch}/orchestration/" 2>/dev/null || true
    touch "${dest_orch}/handoffs/.gitkeep"
    ln -sfn "${core_dir}/CHARTER.md" "${dest_orch}/AGENTS.md"
    ln -sfn "${canonical_repo}/config/agy/GEMINI.md" "${dest_orch}/GEMINI.md"

    if [ -L "${dest_agents}" ]; then
        rm -f "${dest_agents}"
    elif [ -d "${dest_agents}" ]; then
        local bak_agents="${dest_agents}.pre-harness.bak"
        if [ ! -e "$bak_agents" ]; then
            mv "$dest_agents" "$bak_agents"
            echo "  ⚠️ Warning: Pre-existing directory ${dest_agents} backed up to ${bak_agents}"
        else
            echo "  ⚠️ Warning: Pre-existing directory ${dest_agents} already backed up at ${bak_agents}"
        fi
    elif [ -e "${dest_agents}" ]; then
        local bak_agents="${dest_agents}.pre-harness.bak"
        mv "$dest_agents" "$bak_agents"
        echo "  ⚠️ Warning: Pre-existing file ${dest_agents} backed up to ${bak_agents}"
    fi
    ln -sfn .orchestration "${dest_agents}"

    link_workspace_entrypoints "${repo_path}"

    ensure_gitignore_entries "${repo_path}/.gitignore" ".agents/" ".opencode/" ".claude/" ".orchestration/worktrees/" ".orchestration/tmp/" ".orchestration_root"
    echo "  ✅ Installed Antigravity operational assets to ${dest_orch}/ and linked ${dest_agents}"
}

install_claude_local() {
    local repo_path="$TARGET_REPO"
    local dest_claude="${repo_path}/.claude"
    local claude_cfg="${SCRIPT_DIR}/config/claude"
    local canonical_repo="$(resolve_canonical_repo_dir)"
    local core_dir="${SCRIPT_DIR}/core"
    [ -d "$core_dir" ] || core_dir="${canonical_repo}/core"

    echo "================================================================================"
    echo "🚀 INSTALLING CLAUDE CODE HARNESS (LOCAL REPOSITORY MODE)"
    echo "   Repository    : ${repo_path}"
    echo "   Claude Target : ${dest_claude}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would deploy agents/, skills/, rules/, settings/, orchestration/ to ${dest_claude}/"
        echo "  [DRY-RUN] Would merge ${dest_claude}/settings.json preserving custom user config"
        echo "  [DRY-RUN] Ensure ${repo_path}/.gitignore ignores .claude/"
        return 0
    fi

    mkdir -p "${dest_claude}/agents" "${dest_claude}/skills" "${dest_claude}/rules" "${dest_claude}/commands" "${dest_claude}/settings" "${dest_claude}/tools" "${dest_claude}/orchestration"

    find "${dest_claude}/rules" -xtype l -delete 2>/dev/null || true
    find "${dest_claude}/skills" -xtype l -delete 2>/dev/null || true
    find "${dest_claude}/commands" -xtype l -delete 2>/dev/null || true
    find "${dest_claude}/tools" -xtype l -delete 2>/dev/null || true

    python3 -m harness.installer.compiler \
        --core-dir "${core_dir}" \
        --runtime claude \
        --output-dir "${dest_claude}/agents"

    ln -sfn "${core_dir}/CHARTER.md" "${dest_claude}/CLAUDE.md"

    for r in "${core_dir}/rules"/*.md; do
        [ -f "$r" ] || continue
        ln -sfn "$r" "${dest_claude}/rules/$(basename "$r")"
    done

    for skill_path in "${core_dir}/skills"/*; do
        if [ -d "$skill_path" ]; then
            ln -sfn "$skill_path" "${dest_claude}/skills/$(basename "$skill_path")"
        fi
    done

    for c in "${core_dir}/commands"/*.md; do
        [ -f "$c" ] || continue
        ln -sfn "$c" "${dest_claude}/commands/$(basename "$c")"
    done

    for tool_path in "${canonical_repo}/scripts"/*.py "${canonical_repo}/scripts"/*.sh; do
        [ -f "$tool_path" ] || continue
        ln -sfn "$tool_path" "${dest_claude}/tools/$(basename "$tool_path")"
        chmod +x "$tool_path" 2>/dev/null || true
    done
    cp -rf "${canonical_repo}/config/orchestration/"* "${dest_claude}/orchestration/" 2>/dev/null || true

    local template_settings=("${claude_cfg}/settings/core.json")
    if [ -f "${claude_cfg}/settings/readonly.json" ]; then
        template_settings+=("${claude_cfg}/settings/readonly.json")
    fi
    python3 -m harness.installer.settings merge-claude \
        --user-settings "${dest_claude}/settings.json" \
        --template-settings "${template_settings[@]}" \
        --output "${dest_claude}/settings.json"

    link_workspace_entrypoints "${repo_path}"
    ensure_gitignore_entries "${repo_path}/.gitignore" ".claude/" ".orchestration_root"
    echo "  ✅ Installed Claude Code local configuration to ${dest_claude}/"
}

install_opencode_local() {
    local repo_path="$TARGET_REPO"
    local dest_opencode="${repo_path}/.opencode"
    local canonical_repo="$(resolve_canonical_repo_dir)"
    local core_dir="${SCRIPT_DIR}/core"
    [ -d "$core_dir" ] || core_dir="${canonical_repo}/core"
    local py_bin="python3"
    if [ -x "${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
        py_bin="${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
    fi

    echo "================================================================================"
    echo "🚀 INSTALLING OPENCODE HARNESS (LOCAL REPOSITORY MODE)"
    echo "   Repository    : ${repo_path}"
    echo "   OpenCode Dir  : ${dest_opencode}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would deploy 10-component hierarchy (including orchestration/) to ${dest_opencode}/"
        echo "  [DRY-RUN] Ensure ${repo_path}/.gitignore ignores .opencode/"
        return 0
    fi

    mkdir -p "${dest_opencode}/agents" "${dest_opencode}/commands" "${dest_opencode}/skills" "${dest_opencode}/tools" "${dest_opencode}/rules" "${dest_opencode}/plugins" "${dest_opencode}/themes" "${dest_opencode}/orchestration"

    find "${dest_opencode}/rules" -xtype l -delete 2>/dev/null || true
    find "${dest_opencode}/skills" -xtype l -delete 2>/dev/null || true
    find "${dest_opencode}/commands" -xtype l -delete 2>/dev/null || true
    find "${dest_opencode}/tools" -xtype l -delete 2>/dev/null || true

    rm -f "${dest_opencode}/agents/compaction.md" "${dest_opencode}/agents/summary.md"

    local model_profile_arg=()
    if [ "$SGLANG_MODEL" = "qwen-3.8-nvfp4" ] || [ "$SGLANG_MODEL" = "qwen3.8" ] || [ "$SGLANG_MODEL" = "qwen3.8-27b" ] || [ "$SGLANG_MODEL" = "27b-nvfp4" ] || [ "$SGLANG_MODEL" = "qwen-3.8-q6" ] || [ "$SGLANG_MODEL" = "27b-q6" ]; then
        model_profile_arg=(--model-profile "qwen3.8-27b")
    elif [ "$SGLANG_MODEL" = "ornith-9b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-9b" ]; then
        model_profile_arg=(--model-profile "ornith-1.5-9b")
    elif [ "$SGLANG_MODEL" = "ornith-35b" ] || [ "$SGLANG_MODEL" = "ornith-1.5-35b" ]; then
        model_profile_arg=(--model-profile "ornith-1.5-35b")
    fi

    python3 -m harness.installer.compiler \
        --core-dir "${core_dir}" \
        --runtime opencode \
        --output-dir "${dest_opencode}/agents" \
        "${model_profile_arg[@]}"

    rm -f "${dest_opencode}/agents/compaction.md" "${dest_opencode}/agents/summary.md"

    ln -sfn "${core_dir}/CHARTER.md" "${dest_opencode}/AGENTS.md"

    for r in "${core_dir}/rules"/*.md; do
        [ -f "$r" ] || continue
        ln -sfn "$r" "${dest_opencode}/rules/$(basename "$r")"
    done

    for skill_path in "${core_dir}/skills"/*; do
        if [ -d "$skill_path" ]; then
            ln -sfn "$skill_path" "${dest_opencode}/skills/$(basename "$skill_path")"
        fi
    done

    for c in "${core_dir}/commands"/*.md; do
        [ -f "$c" ] || continue
        ln -sfn "$c" "${dest_opencode}/commands/$(basename "$c")"
    done

    for tool_path in "${canonical_repo}/scripts"/*.py "${canonical_repo}/scripts"/*.sh; do
        [ -f "$tool_path" ] || continue
        ln -sfn "$tool_path" "${dest_opencode}/tools/$(basename "$tool_path")"
        chmod +x "$tool_path" 2>/dev/null || true
    done

    cp -rf "${canonical_repo}/config/opencode/plugins/"* "${dest_opencode}/plugins/" 2>/dev/null || true
    cp -rf "${canonical_repo}/config/opencode/themes/"* "${dest_opencode}/themes/" 2>/dev/null || true
    cp -rf "${canonical_repo}/config/orchestration/"* "${dest_opencode}/orchestration/" 2>/dev/null || true
    cp -f "${canonical_repo}/config/opencode/tui.json" "${dest_opencode}/tui.json" 2>/dev/null || true

    if [ ! -f "${dest_opencode}/opencode.json" ]; then
        if [ -f "${SCRIPT_DIR}/config/opencode/opencode.json" ]; then
            cp -f "${SCRIPT_DIR}/config/opencode/opencode.json" "${dest_opencode}/opencode.json"
        else
            cp -f "${canonical_repo}/config/opencode/opencode.json" "${dest_opencode}/opencode.json"
        fi
    fi

    python3 -m harness.installer.config_sync sync-opencode \
        --opencode-json "${dest_opencode}/opencode.json" \
        --repo-dir "${canonical_repo}" \
        --py-bin "${py_bin}" \
        --orch-dir "${repo_path}/.orchestration" \
        --opencode-dir "${dest_opencode}" \
        --sglang-model "${SGLANG_MODEL:-}"

    if [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]] && [ "$DRY_RUN" != true ]; then
        rm -f "${USER_HOME}/.t3/caches/opencode.json"
        if command -v systemctl >/dev/null 2>&1; then
            systemctl --user try-restart opencode-server.service 2>/dev/null || true
        fi
    fi

    if [ "$ENABLE_SYSTEMD" = true ]; then
        setup_backend_environment "${BACKEND_DIR}"
        deploy_opencode_backend_and_units "${SYSTEMD_USER_DIR}" "${BACKEND_DIR}"
    fi

    link_workspace_entrypoints "${repo_path}"
    ensure_gitignore_entries "${repo_path}/.gitignore" ".opencode/" ".orchestration_root"
    echo "  ✅ Installed OpenCode 10-component hierarchy to ${dest_opencode}/"
}

# --- UNIFIED ALL INSTALLERS ---------------------------------------------------

install_all_global() {
    install_agy_global
    install_claude_global
    install_opencode_global
}

install_all_local() {
    install_agy_local
    install_claude_local
    install_opencode_local
    ensure_gitignore_entries "${TARGET_REPO}/.gitignore" ".agents/" ".claude/" ".opencode/" ".orchestration/worktrees/" ".orchestration/tmp/" ".orchestration_root"
}

# --- ACTION EXECUTORS ---------------------------------------------------------

run_install() {
    local recorded_roots=()
    local recorded_symlinks=()
    local recorded_files=()
    local manifest_file=""

    if [ "$MODE" = "local" ]; then
        manifest_file="${TARGET_REPO}/.orchestration/install_manifest.json"
        if [ "$DRY_RUN" = true ]; then
            echo "  [DRY-RUN] Would write ${TARGET_REPO}/.orchestration_root and ${TARGET_REPO}/.orchestration/.orchestration_root"
        else
            mkdir -p "${TARGET_REPO}/.orchestration"
            cat << EOF > "${TARGET_REPO}/.orchestration_root"
mode=local
root=${TARGET_REPO}/.orchestration
EOF
            cat << EOF > "${TARGET_REPO}/.orchestration/.orchestration_root"
mode=local
root=${TARGET_REPO}/.orchestration
EOF
        fi
        recorded_files+=("${TARGET_REPO}/.orchestration_root")
        ensure_gitignore_entries "${TARGET_REPO}/.gitignore" ".orchestration_root"
        case "$TARGET" in
            agy|antigravity|gemini)
                install_agy_local
                recorded_roots+=("${TARGET_REPO}/.orchestration")
                recorded_symlinks+=("${TARGET_REPO}/.agents:.orchestration")
                ;;
            claude|anthropic)
                mkdir -p "${TARGET_REPO}/.orchestration"
                install_claude_local
                recorded_roots+=("${TARGET_REPO}/.claude")
                ;;
            opencode|sglang)
                mkdir -p "${TARGET_REPO}/.orchestration"
                install_opencode_local
                recorded_roots+=("${TARGET_REPO}/.opencode")
                if [ "$ENABLE_SYSTEMD" = true ]; then
                    for u in "${SYSTEMD_UNITS[@]}"; do
                        if [ -f "${SYSTEMD_USER_DIR}/${u}" ] || [ -L "${SYSTEMD_USER_DIR}/${u}" ]; then
                            recorded_files+=("${SYSTEMD_USER_DIR}/${u}")
                        fi
                    done
                fi
                ;;
            all)
                install_all_local
                recorded_roots+=("${TARGET_REPO}/.orchestration" "${TARGET_REPO}/.claude" "${TARGET_REPO}/.opencode")
                recorded_symlinks+=("${TARGET_REPO}/.agents:.orchestration")
                if [ "$ENABLE_SYSTEMD" = true ]; then
                    for u in "${SYSTEMD_UNITS[@]}"; do
                        if [ -f "${SYSTEMD_USER_DIR}/${u}" ] || [ -L "${SYSTEMD_USER_DIR}/${u}" ]; then
                            recorded_files+=("${SYSTEMD_USER_DIR}/${u}")
                        fi
                    done
                fi
                ;;
            *)
                echo "❌ Error: Unknown target '${TARGET}'. Supported: agy, claude, opencode, all" >&2
                exit 1
                ;;
        esac

        if [ "$DRY_RUN" = false ]; then
            local file_args=()
            if [ ${#recorded_files[@]} -gt 0 ]; then
                file_args=(--files "${recorded_files[@]}")
            fi
            python3 -m harness.installer.manifest record \
                --manifest-path "$manifest_file" \
                --target "$TARGET" \
                --mode "$MODE" \
                --roots "${recorded_roots[@]}" \
                --symlinks "${recorded_symlinks[@]}" \
                "${file_args[@]}"
        fi
        warmup_sglang_service
        verify_backend_healthchecks
        guided_configuration_wizard
        human_confirmed_t3_gate
        print_pending_sudo_summary
        print_completion_summary
        if [ "$T3_GATE_CONFIRMED" = true ]; then
            echo "🎉 Local Agent Harness installation complete!"
        else
            echo "⏳ Backend services installed; the guided T3 completion gate is pending your"
            echo "   confirmation. Re-run ./install.sh interactively to finish, or confirm it from the dashboard above."
        fi
    else
        manifest_file="${USER_HOME}/.orchestration/install_manifest.json"
        if [ "$DRY_RUN" = true ]; then
            echo "  [DRY-RUN] Would write ${USER_HOME}/.orchestration/.orchestration_root"
        else
            mkdir -p "${USER_HOME}/.orchestration"
            cat << EOF > "${USER_HOME}/.orchestration/.orchestration_root"
mode=global
root=${USER_HOME}/.orchestration
EOF
        fi
        case "$TARGET" in
            agy|antigravity|gemini)
                install_agy_global
                recorded_roots+=("${USER_HOME}/.orchestration" "${GEMINI_CONFIG_DIR}/plugins/agent-harness")
                recorded_symlinks+=("${USER_HOME}/.agents:${USER_HOME}/.orchestration" "${GEMINI_CONFIG_DIR}/plugins/agy-harness:${GEMINI_CONFIG_DIR}/plugins/agent-harness")
                ;;
            claude|anthropic)
                mkdir -p "${USER_HOME}/.orchestration"
                install_claude_global
                recorded_roots+=("${USER_HOME}/.claude")
                ;;
            opencode|sglang)
                mkdir -p "${USER_HOME}/.orchestration"
                install_opencode_global
                recorded_roots+=("${USER_HOME}/.config/opencode")
                for u in "${SYSTEMD_UNITS[@]}"; do
                    if [ -f "${SYSTEMD_USER_DIR}/${u}" ] || [ -L "${SYSTEMD_USER_DIR}/${u}" ]; then
                        recorded_files+=("${SYSTEMD_USER_DIR}/${u}")
                    fi
                done
                install_obsidian
                provision_home_vault
                configure_firewall
                ;;
            all)
                install_all_global
                recorded_roots+=("${USER_HOME}/.orchestration" "${GEMINI_CONFIG_DIR}/plugins/agent-harness" "${USER_HOME}/.claude" "${USER_HOME}/.config/opencode")
                recorded_symlinks+=("${USER_HOME}/.agents:${USER_HOME}/.orchestration" "${GEMINI_CONFIG_DIR}/plugins/agy-harness:${GEMINI_CONFIG_DIR}/plugins/agent-harness")
                for u in "${SYSTEMD_UNITS[@]}"; do
                    if [ -f "${SYSTEMD_USER_DIR}/${u}" ] || [ -L "${SYSTEMD_USER_DIR}/${u}" ]; then
                        recorded_files+=("${SYSTEMD_USER_DIR}/${u}")
                    fi
                done
                install_obsidian
                provision_home_vault
                configure_firewall
                ;;
            *)
                echo "❌ Error: Unknown target '${TARGET}'. Supported: agy, claude, opencode, all" >&2
                exit 1
                ;;
        esac

        if [ "$DRY_RUN" = false ]; then
            local file_args=()
            if [ ${#recorded_files[@]} -gt 0 ]; then
                file_args=(--files "${recorded_files[@]}")
            fi
            python3 -m harness.installer.manifest record \
                --manifest-path "$manifest_file" \
                --target "$TARGET" \
                --mode "$MODE" \
                --roots "${recorded_roots[@]}" \
                --symlinks "${recorded_symlinks[@]}" \
                "${file_args[@]}"
        fi
        warmup_sglang_service
        verify_backend_healthchecks
        guided_configuration_wizard
        human_confirmed_t3_gate
        print_pending_sudo_summary
        print_completion_summary
        if [ "$T3_GATE_CONFIRMED" = true ]; then
            echo "🎉 Global Agent Harness installation complete!"
        else
            echo "⏳ Backend services installed; the guided T3 completion gate is pending your"
            echo "   confirmation. Re-run ./install.sh interactively to finish, or confirm it from the dashboard above."
        fi
    fi
}

run_verify() {
    local manifest_file=""
    if [ "$MODE" = "local" ]; then
        manifest_file="${TARGET_REPO}/.orchestration/install_manifest.json"
    else
        manifest_file="${USER_HOME}/.orchestration/install_manifest.json"
    fi

    if [ ! -f "$manifest_file" ]; then
        echo "❌ Error: Install manifest not found at ${manifest_file}. Cannot verify." >&2
        exit 1
    fi

    python3 -m harness.installer.manifest verify --manifest-path "$manifest_file"
}

run_uninstall() {
    local manifest_file=""
    if [ "$MODE" = "local" ]; then
        manifest_file="${TARGET_REPO}/.orchestration/install_manifest.json"
    else
        manifest_file="${USER_HOME}/.orchestration/install_manifest.json"
    fi

    echo "================================================================================"
    echo "🗑️ UNINSTALLING AGENT HARNESS (${MODE^^} MODE)"
    echo "   Manifest  : ${manifest_file}"
    echo "   Dry Run   : ${DRY_RUN}"
    echo "================================================================================"

    local manifest_args=()
    if [ "$DRY_RUN" = true ]; then
        manifest_args+=(--dry-run)
    fi
    if [ "$NO_BACKUP" = true ]; then
        manifest_args+=(--no-backup)
    fi
    if [ "$WIPE_BACKUPS" = true ]; then
        manifest_args+=(--wipe-backups)
    fi

    if [ -f "$manifest_file" ]; then
        python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" "${manifest_args[@]}"
    elif [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] SIMULATING uninstallation of agent-harness components..."
        if [ "$PURGE" = true ]; then
            echo "Purging backend stacks and configuration..."
            echo "[DRY-RUN] Would remove directory ${SGLANG_STACK_DIR}"
            echo "[DRY-RUN] Would remove directory ${BACKEND_DIR}"
        fi
        exit 0
    fi

    if [ "$MODE" = "global" ]; then
        if [ "$DRY_RUN" = false ]; then
            for l in opencode-local opencode-architect-local opencode-worker-local opencode-reviewer-local opencode-sub-agent-local; do
                rm -f "${USER_HOME}/.local/bin/$l"
            done

            local systemd_user_dir="${SYSTEMD_USER_DIR:-${USER_HOME}/.config/systemd/user}"
            if [ -d "${systemd_user_dir}" ]; then
                for u_name in "${SYSTEMD_UNITS[@]}"; do
                    local u="${systemd_user_dir}/${u_name}"
                    if [ -f "$u" ]; then
                        if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]]; then
                            systemctl --user stop "$u_name" 2>/dev/null || true
                            systemctl --user disable "$u_name" 2>/dev/null || true
                        fi
                        rm -f "$u"
                    fi
                done
                for u in "${systemd_user_dir}"/opencode-*.service "${systemd_user_dir}"/opencode-*.timer "${systemd_user_dir}"/opencode-*.slice; do
                    if [ -f "$u" ]; then
                        local unit_name="$(basename "$u")"
                        if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]]; then
                            systemctl --user stop "$unit_name" 2>/dev/null || true
                            systemctl --user disable "$unit_name" 2>/dev/null || true
                        fi
                        rm -f "$u"
                    fi
                done
                if command -v systemctl >/dev/null 2>&1 && [ "${USER_HOME}" = "${HOME}" ] && ! [[ "${USER_HOME}" =~ ^/tmp/|sandbox|mock|tmp\. ]]; then
                    systemctl --user daemon-reload 2>/dev/null || true
                fi
            fi

            # Clean symlinks
            [ -L "${GEMINI_CONFIG_DIR}/plugins/agy-harness" ] && rm -f "${GEMINI_CONFIG_DIR}/plugins/agy-harness"

            # Clean AGY global entrypoints/rules that live outside the recorded roots (harness-owned artifacts only)
            python3 -m harness.installer.config_sync unsync-gemini --gemini-md "${USER_HOME}/.gemini/GEMINI.md" || true
            if [ -L "${USER_HOME}/.gemini/AGENTS.md" ]; then
                case "$(readlink "${USER_HOME}/.gemini/AGENTS.md")" in
                    */core/CHARTER.md) rm -f "${USER_HOME}/.gemini/AGENTS.md" ;;
                esac
            fi
            for rule_link in "${GEMINI_CONFIG_DIR}/rules"/*.md; do
                [ -L "$rule_link" ] || continue
                case "$(readlink "$rule_link")" in
                    */core/rules/*.md) rm -f "$rule_link" ;;
                esac
            done
            rmdir "${GEMINI_CONFIG_DIR}/rules" 2>/dev/null || true
            [ -L "${AGENTS_HOME_DIR}" ] && rm -f "${AGENTS_HOME_DIR}"

            # Handle pre-existing settings and backup restoration/wiping
            if [ "$WIPE_BACKUPS" = true ]; then
                rm -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak"
                rm -rf "${AGENTS_HOME_DIR}.pre-harness.bak"
                find "${USER_HOME}/.orchestration" "${GEMINI_CONFIG_DIR}" "${CLAUDE_HOME_DIR}" "${OPENCODE_HOME_DIR}" -name "*.pre-harness.bak" -exec rm -rf {} + 2>/dev/null || true
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

            if [ "$PURGE" = true ]; then
                rm -rf "${SGLANG_STACK_DIR}"
                rm -rf "${BACKEND_DIR}"
                echo "✅ Purged backend stacks and configurations."
            fi
            echo "✅ Removed global harness files."
        fi
    else
        if [ "$DRY_RUN" = false ]; then
            # Clean anchor files
            rm -f "${TARGET_REPO}/.orchestration_root" "${TARGET_REPO}/.orchestration/.orchestration_root"

            # Only remove .agents if it is a symlink
            if [ -L "${TARGET_REPO}/.agents" ]; then
                rm -f "${TARGET_REPO}/.agents"
            fi

            # Remove workspace entrypoint symlinks created by the installer (never user-authored files)
            for entry_link in AGENTS.md GEMINI.md CLAUDE.md; do
                if [ -L "${TARGET_REPO}/${entry_link}" ]; then
                    case "$(readlink "${TARGET_REPO}/${entry_link}")" in
                        .agents/AGENTS.md|.agents/GEMINI.md|AGENTS.md) rm -f "${TARGET_REPO}/${entry_link}" ;;
                    esac
                fi
            done

            # Handle pre-existing settings and backup restoration/wiping
            if [ "$WIPE_BACKUPS" = true ]; then
                rm -f "${TARGET_REPO}/.claude/settings.json.pre-harness.bak"
                rm -rf "${TARGET_REPO}/.agents.pre-harness.bak"
                find "${TARGET_REPO}/.orchestration" "${TARGET_REPO}/.claude" "${TARGET_REPO}/.opencode" -name "*.pre-harness.bak" -exec rm -rf {} + 2>/dev/null || true
                echo "✅ Purged pre-harness backup files and directories in ${TARGET_REPO}."
            elif [ "$NO_BACKUP" = false ]; then
                if [ -f "${TARGET_REPO}/.claude/settings.json.pre-harness.bak" ]; then
                    mv -f "${TARGET_REPO}/.claude/settings.json.pre-harness.bak" "${TARGET_REPO}/.claude/settings.json"
                fi
                if [ -d "${TARGET_REPO}/.agents.pre-harness.bak" ] && [ ! -e "${TARGET_REPO}/.agents" ]; then
                    mv "${TARGET_REPO}/.agents.pre-harness.bak" "${TARGET_REPO}/.agents"
                fi
            fi

            # In local mode, remove uninstaller logs and directories if clean
            if [ -d "${TARGET_REPO}/.orchestration/logs" ]; then
                rm -rf "${TARGET_REPO}/.orchestration/logs"
            fi

            # Safely clean empty directories only - preserve any user-modified files
            for d in "${TARGET_REPO}/.agents" "${TARGET_REPO}/.claude" "${TARGET_REPO}/.opencode" "${TARGET_REPO}/.orchestration"; do
                if [ -d "$d" ]; then
                    find "$d" -depth -type d -empty -delete 2>/dev/null || true
                    rmdir "$d" 2>/dev/null || true
                fi
            done
            echo "✅ Removed ${TARGET_REPO}/.agents and ${TARGET_REPO}/.orchestration"
        fi
    fi
}

# Main Routing
case "$ACTION" in
    install)
        run_install
        ;;
    verify)
        run_verify
        ;;
    uninstall)
        run_uninstall
        ;;
    *)
        echo "❌ Error: Unknown action: ${ACTION}. Supported: install, uninstall, verify" >&2
        exit 1
        ;;
esac
