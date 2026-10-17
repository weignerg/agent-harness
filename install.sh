#!/usr/bin/env bash
# ==============================================================================
# install.sh - Unified Agent Harness Multi-Runtime Installer
#
# Targets:
#   --target=agy (default)   Deploy Antigravity (Gemini 3.8) plugin & tools
#   --target=claude          Deploy Claude Code (Anthropic) settings & agents
#   --target=opencode        Deploy OpenCode (SGLang) configurations & commands
#   --target=all             Deploy all supported runtime integrations
#
# Modes:
#   --global (default)       Deploy runtime plugins/settings to user home
#   --local [<repo_path>]    Deploy inert templates into <repo_path>
#   --repo [<repo_path>]     Alias for --local [<repo_path>]
#
# Options:
#   -n, --dry-run            Simulate installation without modifying files
#   -y, --non-interactive    Run without interactive prompts
#   --reinstall              Force clean re-deployment of harness files
#   -h, --help               Show usage help
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USER_HOME="${USER_HOME:-${HOME}}"
GEMINI_CONFIG_DIR="${GEMINI_CONFIG_DIR:-${USER_HOME}/.gemini/config}"
AGENTS_HOME_DIR="${AGENTS_HOME_DIR:-${USER_HOME}/.agents}"
CLAUDE_HOME_DIR="${CLAUDE_HOME_DIR:-${USER_HOME}/.claude}"
OPENCODE_HOME_DIR="${OPENCODE_HOME_DIR:-${USER_HOME}/.config/opencode}"

MODE="global"
TARGET="agy"
TARGET_REPO=""
DRY_RUN=false
NON_INTERACTIVE=false
REINSTALL=false

show_help() {
    sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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

ensure_gitignore_entries() {
    local gitignore_file="$1"
    shift
    local entries=("$@")

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Ensure ${gitignore_file} ignores: ${entries[*]}"
        return 0
    fi

    touch "$gitignore_file"
    for entry in "${entries[@]}"; do
        if ! grep -qxF "$entry" "$gitignore_file" 2>/dev/null; then
            echo "$entry" >> "$gitignore_file"
            echo "  ✅ Added '${entry}' to ${gitignore_file}"
        fi
    done
}

install_agy_global() {
    local plugin_dest="${GEMINI_CONFIG_DIR}/plugins/agy-harness"
    local legacy_plugin="${GEMINI_CONFIG_DIR}/plugins/local-blackwell"
    local mcp_config="${GEMINI_CONFIG_DIR}/mcp_config.json"
    local agy_tmpl="${SCRIPT_DIR}/templates/agy"

    echo "================================================================================"
    echo "🚀 INSTALLING AGY HARNESS (GLOBAL MODE)"
    echo "   Plugin Target : ${plugin_dest}"
    echo "   Agents Target : ${AGENTS_HOME_DIR}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would remove legacy ${legacy_plugin} and stale ${USER_HOME}/AGENTS.md"
        echo "  [DRY-RUN] Would prune stale *.md in ${plugin_dest}/agents/"
        echo "  [DRY-RUN] Would copy ${agy_tmpl}/plugins/agy-harness/* to ${plugin_dest}/"
        echo "  [DRY-RUN] Would deploy rules/, skills/, tools/, orchestration/, handoffs/ to ${AGENTS_HOME_DIR}/"
        echo "  [DRY-RUN] Would register vault-memory and worktree-manager in ${mcp_config}"
        return 0
    fi

    rm -rf "$legacy_plugin"
    rm -f "${USER_HOME}/AGENTS.md"
    mkdir -p "${plugin_dest}/agents"
    rm -f "${plugin_dest}/agents/"*.md
    cp -f "${agy_tmpl}/plugins/agy-harness/plugin.json" "${plugin_dest}/plugin.json"
    cp -f "${agy_tmpl}/plugins/agy-harness/agents/"*.md "${plugin_dest}/agents/"
    echo "  ✅ Installed canonical Gemini 3.8 agent profiles in ${plugin_dest}/agents/"

    mkdir -p "${AGENTS_HOME_DIR}/rules" "${AGENTS_HOME_DIR}/skills" "${AGENTS_HOME_DIR}/tools" "${AGENTS_HOME_DIR}/handoffs" "${AGENTS_HOME_DIR}/orchestration"
    cp -rf "${agy_tmpl}/rules/"* "${AGENTS_HOME_DIR}/rules/"
    cp -rf "${agy_tmpl}/skills/"* "${AGENTS_HOME_DIR}/skills/"
    cp -rf "${agy_tmpl}/tools/"* "${AGENTS_HOME_DIR}/tools/"
    chmod +x "${AGENTS_HOME_DIR}/tools/"*.sh 2>/dev/null || true
    cp -rf "${agy_tmpl}/orchestration/"* "${AGENTS_HOME_DIR}/orchestration/"
    cp -f "${agy_tmpl}/handoffs/.gitkeep" "${AGENTS_HOME_DIR}/handoffs/.gitkeep"
    cp -f "${agy_tmpl}/AGENTS.md" "${AGENTS_HOME_DIR}/AGENTS.md"
    cp -f "${agy_tmpl}/GEMINI.md" "${AGENTS_HOME_DIR}/GEMINI.md"
    rm -f "${AGENTS_HOME_DIR}/rules.md"
    echo "  ✅ Synced rules, skills, tools, and charters to ${AGENTS_HOME_DIR}/"

    mkdir -p "$(dirname "$mcp_config")"
    local py_bin="python3"
    if [ -x "${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python" ]; then
        py_bin="${USER_HOME}/.local/share/opencode-sglang-stack/venv/bin/python"
    fi

    local canonical_repo="$SCRIPT_DIR"
    if git -C "$SCRIPT_DIR" rev-parse --git-common-dir >/dev/null 2>&1; then
        local common_git
        common_git="$(cd "$SCRIPT_DIR" && cd "$(git rev-parse --git-common-dir)" && pwd)"
        if [[ "$(basename "$common_git")" == ".git" ]]; then
            canonical_repo="$(dirname "$common_git")"
        fi
    fi

    python3 - "$mcp_config" "$canonical_repo" "$py_bin" <<'PYEOF'
import json
import sys
from pathlib import Path

mcp_path = Path(sys.argv[1])
repo_dir = sys.argv[2]
py_bin = sys.argv[3]

data = {}
if mcp_path.is_file():
    try:
        data = json.loads(mcp_path.read_text(encoding="utf-8"))
    except Exception:
        data = {}

if not isinstance(data, dict):
    data = {}
servers = data.setdefault("mcpServers", {})

servers["vault-memory"] = {
    "command": py_bin,
    "args": ["-m", "harness.mcp.vault_server"],
    "env": {"PYTHONPATH": repo_dir},
}
servers["worktree-manager"] = {
    "command": py_bin,
    "args": ["-m", "harness.mcp.worktree_server"],
    "env": {"PYTHONPATH": repo_dir},
}

mcp_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYEOF
    echo "  ✅ Registered vault-memory and worktree-manager in ${mcp_config}"
}

install_claude_global() {
    local claude_dest="${CLAUDE_HOME_DIR}"
    local claude_tmpl="${SCRIPT_DIR}/templates/claude"

    echo "================================================================================"
    echo "🚀 INSTALLING CLAUDE CODE HARNESS (GLOBAL MODE)"
    echo "   Target Dir    : ${claude_dest}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would deploy agents/, skills/, rules/, settings/ to ${claude_dest}/"
        return 0
    fi

    mkdir -p "${claude_dest}/agents" "${claude_dest}/skills" "${claude_dest}/rules" "${claude_dest}/settings"
    cp -rf "${claude_tmpl}/agents/"* "${claude_dest}/agents/"
    cp -rf "${claude_tmpl}/skills/"* "${claude_dest}/skills/"
    cp -rf "${claude_tmpl}/rules/"* "${claude_dest}/rules/"
    cp -rf "${claude_tmpl}/settings/"* "${claude_dest}/settings/"
    cp -f "${claude_tmpl}/CLAUDE.md" "${claude_dest}/CLAUDE.md"
    echo "  ✅ Installed Claude Code agents, skills, and configuration to ${claude_dest}/"
}

install_opencode_global() {
    local opencode_dest="${OPENCODE_HOME_DIR}"
    local opencode_tmpl="${SCRIPT_DIR}/templates/opencode"
    local legacy_launchers=("opencode-local" "opencode-architect-local" "opencode-worker-local" "opencode-reviewer-local" "opencode-sub-agent-local")

    local backend_env_dir="${USER_HOME}/.config/opencode-backends"

    echo "================================================================================"
    echo "🚀 INSTALLING OPENCODE HARNESS (GLOBAL MODE)"
    echo "   Target Dir    : ${opencode_dest}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would ensure ${backend_env_dir}/env exists for backend services"
        echo "  [DRY-RUN] Would prune legacy launchers in ${USER_HOME}/.local/bin/"
        echo "  [DRY-RUN] Would deploy agents/, commands/, skills/, tools/, rules/, plugins/, themes/, opencode.json to ${opencode_dest}/"
        return 0
    fi

    mkdir -p "${backend_env_dir}"
    if [ ! -f "${backend_env_dir}/env" ]; then
        touch "${backend_env_dir}/env"
        chmod 0600 "${backend_env_dir}/env"
    fi

    for legacy_launcher in "${legacy_launchers[@]}"; do
        rm -f "${USER_HOME}/.local/bin/${legacy_launcher}"
    done

    mkdir -p "${opencode_dest}/agents" "${opencode_dest}/commands" "${opencode_dest}/skills" "${opencode_dest}/tools" "${opencode_dest}/rules" "${opencode_dest}/plugins" "${opencode_dest}/themes"
    cp -rf "${opencode_tmpl}/agents/"* "${opencode_dest}/agents/"
    cp -rf "${opencode_tmpl}/commands/"* "${opencode_dest}/commands/"
    cp -rf "${opencode_tmpl}/skills/"* "${opencode_dest}/skills/"
    cp -rf "${opencode_tmpl}/tools/"* "${opencode_dest}/tools/"
    chmod +x "${opencode_dest}/tools/"*.sh "${opencode_dest}/tools/"*.py 2>/dev/null || true
    cp -rf "${opencode_tmpl}/rules/"* "${opencode_dest}/rules/"
    cp -rf "${opencode_tmpl}/plugins/"* "${opencode_dest}/plugins/"
    cp -rf "${opencode_tmpl}/themes/"* "${opencode_dest}/themes/"
    cp -f "${opencode_tmpl}/opencode.json" "${opencode_dest}/opencode.json"
    cp -f "${opencode_tmpl}/tui.json" "${opencode_dest}/tui.json"
    cp -f "${opencode_tmpl}/AGENTS.md" "${opencode_dest}/AGENTS.md"
    echo "  ✅ Installed OpenCode 10-component hierarchy to ${opencode_dest}/"
}

install_local_repo() {
    local repo_path
    repo_path="$(mkdir -p "$TARGET_REPO" && cd "$TARGET_REPO" && pwd)"
    local dest_agents="${repo_path}/.agents"
    local dest_orch="${repo_path}/.orchestration"
    local agy_tmpl="${SCRIPT_DIR}/templates/agy"

    echo "================================================================================"
    echo "🚀 INSTALLING AGENT HARNESS (LOCAL REPOSITORY MODE)"
    echo "   Repository    : ${repo_path}"
    echo "   Target Dir    : ${dest_agents}"
    echo "   Orchestration : ${dest_orch}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would deploy rules/, skills/, tools/, handoffs/, GEMINI.md, AGENTS.md into ${dest_agents}/"
        echo "  [DRY-RUN] Would create canonical .orchestration/ structure in ${dest_orch}/"
        echo "  [DRY-RUN] Ensure ${repo_path}/.gitignore ignores .agents/, .opencode/, and .orchestration/worktrees/"
        return 0
    fi

    if [ "$REINSTALL" = true ] && [ -d "$dest_agents" ]; then
        rm -rf "${dest_agents}/rules" "${dest_agents}/skills" "${dest_agents}/tools" "${dest_agents}/orchestration"
    fi

    mkdir -p "${dest_agents}/rules" "${dest_agents}/skills" "${dest_agents}/tools" "${dest_agents}/handoffs" "${dest_agents}/orchestration"
    cp -rf "${agy_tmpl}/rules/"* "${dest_agents}/rules/"
    cp -rf "${agy_tmpl}/skills/"* "${dest_agents}/skills/"
    cp -rf "${agy_tmpl}/tools/"* "${dest_agents}/tools/"
    chmod +x "${dest_agents}/tools/"*.sh 2>/dev/null || true
    cp -rf "${agy_tmpl}/orchestration/"* "${dest_agents}/orchestration/"
    cp -f "${agy_tmpl}/handoffs/.gitkeep" "${dest_agents}/handoffs/.gitkeep"
    cp -f "${agy_tmpl}/GEMINI.md" "${dest_agents}/GEMINI.md"
    cp -f "${agy_tmpl}/AGENTS.md" "${dest_agents}/AGENTS.md"

    # Deploy canonical .orchestration/ runtime layout
    mkdir -p "${dest_orch}/handoffs" "${dest_orch}/memory" "${dest_orch}/worktrees" "${dest_orch}/logs" "${dest_orch}/tmp"
    touch "${dest_orch}/handoffs/.gitkeep" "${dest_orch}/memory/.gitkeep" "${dest_orch}/logs/.gitkeep" "${dest_orch}/tmp/.gitkeep"

    echo "  ✅ Populated ${dest_agents}/ and ${dest_orch}/"

    echo "[2/2] Updating ${repo_path}/.gitignore..."
    ensure_gitignore_entries "${repo_path}/.gitignore" ".agents/" ".opencode/" ".orchestration/worktrees/" ".orchestration/tmp/"

    echo "🎉 Local Agent Harness installation complete!"
}

# Main Execution Routing
if [ "$MODE" = "local" ]; then
    install_local_repo
else
    case "$TARGET" in
        agy|antigravity|gemini)
            install_agy_global
            ;;
        claude|anthropic)
            install_claude_global
            ;;
        opencode|sglang)
            install_opencode_global
            ;;
        all)
            install_agy_global
            install_claude_global
            install_opencode_global
            ;;
        *)
            echo "❌ Error: Unknown target '${TARGET}'. Supported: agy, claude, opencode, all" >&2
            exit 1
            ;;
    esac
fi
