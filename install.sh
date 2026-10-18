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
            elif [[ "$val" == "local" || "$val" == "repo" ]]; then
                MODE="local"
            fi
            shift
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
        --systemd|--with-systemd)
            ENABLE_SYSTEMD=true
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

install_agy_global() {
    local plugin_dest="${GEMINI_CONFIG_DIR}/plugins/agent-harness"
    local legacy_agy_plugin="${GEMINI_CONFIG_DIR}/plugins/agy-harness"
    local legacy_plugin="${GEMINI_CONFIG_DIR}/plugins/local-blackwell"
    local mcp_config="${GEMINI_CONFIG_DIR}/mcp_config.json"
    local agy_tmpl="${SCRIPT_DIR}/templates/agy"
    local orch_dest="${USER_HOME}/.orchestration"
    local agents_link="${USER_HOME}/.agents"

    echo "================================================================================"
    echo "🚀 INSTALLING AGY HARNESS (GLOBAL MODE)"
    echo "   Plugin Target : ${plugin_dest}"
    echo "   Agents Target : ${AGENTS_HOME_DIR}"
    echo "   Orchestration : ${orch_dest}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would remove legacy ${legacy_plugin} and stale ${USER_HOME}/AGENTS.md"
        echo "  [DRY-RUN] Would prune stale *.md in ${plugin_dest}/agents/"
        echo "  [DRY-RUN] Would copy ${agy_tmpl}/plugins/agy-harness/* to ${plugin_dest}/"
        echo "  [DRY-RUN] Would deploy rules/, skills/, tools/, orchestration/, handoffs/ to ${orch_dest}/"
        echo "  [DRY-RUN] Would create symlink ${agents_link} -> ${orch_dest}"
        echo "  [DRY-RUN] Would register vault-memory and worktree-manager in ${mcp_config}"
        return 0
    fi

    rm -rf "$legacy_plugin"
    rm -rf "$legacy_agy_plugin"
    rm -f "${USER_HOME}/AGENTS.md"
    mkdir -p "${plugin_dest}/agents"
    rm -f "${plugin_dest}/agents/"*.md
    cp -f "${agy_tmpl}/plugins/agy-harness/plugin.json" "${plugin_dest}/plugin.json"
    cp -f "${agy_tmpl}/plugins/agy-harness/agents/"*.md "${plugin_dest}/agents/"
    
    mkdir -p "$(dirname "$legacy_agy_plugin")"
    ln -sfn agent-harness "${legacy_agy_plugin}"
    echo "  ✅ Installed canonical Gemini 3.8 agent profiles in ${plugin_dest}/agents/"

    mkdir -p "${orch_dest}/rules" "${orch_dest}/skills" "${orch_dest}/tools" "${orch_dest}/handoffs" "${orch_dest}/orchestration" "${orch_dest}/memory" "${orch_dest}/worktrees" "${orch_dest}/logs" "${orch_dest}/tmp"
    cp -rf "${agy_tmpl}/rules/"* "${orch_dest}/rules/"
    cp -rf "${agy_tmpl}/skills/"* "${orch_dest}/skills/"
    cp -rf "${agy_tmpl}/tools/"* "${orch_dest}/tools/"
    chmod +x "${orch_dest}/tools/"*.sh 2>/dev/null || true
    cp -rf "${agy_tmpl}/orchestration/"* "${orch_dest}/orchestration/"
    cp -f "${agy_tmpl}/handoffs/.gitkeep" "${orch_dest}/handoffs/.gitkeep"
    touch "${orch_dest}/memory/.gitkeep" "${orch_dest}/logs/.gitkeep" "${orch_dest}/tmp/.gitkeep"
    cp -f "${agy_tmpl}/AGENTS.md" "${orch_dest}/AGENTS.md"
    cp -f "${agy_tmpl}/GEMINI.md" "${orch_dest}/GEMINI.md"

    if [ -L "${agents_link}" ]; then
        rm -f "${agents_link}"
    elif [ -d "${agents_link}" ]; then
        # Migrate any user-defined skills, rules, or tools into orch_dest before symlinking
        cp -rn "${agents_link}/skills/"* "${orch_dest}/skills/" 2>/dev/null || true
        cp -rn "${agents_link}/rules/"* "${orch_dest}/rules/" 2>/dev/null || true
        cp -rn "${agents_link}/tools/"* "${orch_dest}/tools/" 2>/dev/null || true
        local bak_agents="${agents_link}.pre-harness.bak"
        if [ ! -e "$bak_agents" ]; then
            cp -r "$agents_link" "$bak_agents"
            echo "  ⚠️ Warning: Pre-existing directory ${agents_link} backed up to ${bak_agents}"
        else
            echo "  ⚠️ Warning: Pre-existing directory ${agents_link} already backed up at ${bak_agents}"
        fi
        rm -rf "$agents_link"
    elif [ -e "${agents_link}" ]; then
        local bak_agents="${agents_link}.pre-harness.bak"
        mv "$agents_link" "$bak_agents"
        echo "  ⚠️ Warning: Pre-existing file ${agents_link} backed up to ${bak_agents}"
    fi
    ln -sfn "${orch_dest}" "${agents_link}"
    rm -f "${orch_dest}/rules.md" 2>/dev/null || true
    echo "  ✅ Synced rules, skills, tools, and charters to ${orch_dest}/"

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
        echo "  [DRY-RUN] Would merge ${claude_dest}/settings.json preserving custom user config"
        return 0
    fi

    mkdir -p "${claude_dest}/agents" "${claude_dest}/skills" "${claude_dest}/rules" "${claude_dest}/settings" "${claude_dest}/tools"
    cp -rf "${claude_tmpl}/agents/"* "${claude_dest}/agents/"
    cp -rf "${claude_tmpl}/skills/"* "${claude_dest}/skills/"
    cp -rf "${claude_tmpl}/rules/"* "${claude_dest}/rules/"
    cp -rf "${claude_tmpl}/tools/"* "${claude_dest}/tools/"
    chmod +x "${claude_dest}/tools/"*.sh "${claude_dest}/tools/"*.py 2>/dev/null || true
    cp -rf "${claude_tmpl}/settings/"* "${claude_dest}/settings/"
    cp -f "${claude_tmpl}/CLAUDE.md" "${claude_dest}/CLAUDE.md"

    local existing_user_settings="${claude_dest}/settings.json"
    if [ -f "$existing_user_settings" ] && [ ! -f "${existing_user_settings}.pre-harness.bak" ]; then
        cp -p "$existing_user_settings" "${existing_user_settings}.pre-harness.bak"
    fi

    python3 -m harness.installer.settings merge-claude \
        --user-settings "${claude_dest}/settings.json" \
        --template-settings "${claude_tmpl}/settings/core.json" \
        --output "${claude_dest}/settings.json"

    echo "  ✅ Installed Claude Code agents, skills, and configuration to ${claude_dest}/"
}

deploy_opencode_backend_and_units() {
    local systemd_dest="$1"
    local backend_env_dir="$2"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would probe GPU hardware and deploy systemd user units to ${systemd_dest}/"
        return 0
    fi

    mkdir -p "${systemd_dest}" "${backend_env_dir}"

    # 1. Run GPU probe to detect hardware profile
    local gpu_profile=""
    local mem_fraction=""
    local max_context=""
    if [ -x "${SCRIPT_DIR}/scripts/gpu_probe.sh" ]; then
        gpu_profile="$("${SCRIPT_DIR}/scripts/gpu_probe.sh" ${OVERRIDE_GPU:+--override-gpu "$OVERRIDE_GPU"} 2>/dev/null || echo '{"profile":"fallback","memory_fraction":0.88,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"unknown device","model":"ornith-1.5-35b","service":"opencode-sglang-ornith-35b.service","cpu_offload_gb":0}')"
    else
        gpu_profile='{"profile":"fallback","memory_fraction":0.88,"max_context":262144,"kv_cache_dtype":"nvfp4","offload":"pure-gpu","gpu":"unknown device","model":"ornith-1.5-35b","service":"opencode-sglang-ornith-35b.service","cpu_offload_gb":0}'
    fi
    echo "  Detected GPU Profile: ${gpu_profile}"
    echo "$gpu_profile" > "${backend_env_dir}/gpu_profile.json"
    mem_fraction="$(printf '%s' "$gpu_profile" | grep -oE '"memory_fraction":[0-9.]+' | grep -oE '[0-9.]+' | head -n1 || echo "0.88")"
    max_context="$(printf '%s' "$gpu_profile" | grep -oE '"max_context":[0-9]+' | grep -oE '[0-9]+' | head -n1 || echo "262144")"
    local probed_model="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('model', 'ornith-1.5-35b'))" "${gpu_profile}" 2>/dev/null || echo "ornith-1.5-35b")"
    local probed_cpu_offload="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('cpu_offload_gb', 0))" "${gpu_profile}" 2>/dev/null || echo 0)"
    local probed_service="$(python3 -c "import json, sys; d=json.loads(sys.argv[1]); print(d.get('service', 'opencode-sglang-ornith-35b.service'))" "${gpu_profile}" 2>/dev/null || echo "opencode-sglang-ornith-35b.service")"

    echo "  ✅ Probed GPU resources: Model=${probed_model}, Context=${max_context}, Service=${probed_service}"

    # Update ${backend_env_dir}/env with probed variables while preserving existing secrets and 0600 mode
    if [ -f "${backend_env_dir}/env" ]; then
        python3 -c "
import sys
path = sys.argv[1]
keys = {
    'PROBED_CONTEXT_LENGTH': sys.argv[2],
    'PROBED_MEM_FRACTION': sys.argv[3],
    'PROBED_MODEL': sys.argv[4],
    'PROBED_CPU_OFFLOAD_GB': sys.argv[5],
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
" "${backend_env_dir}/env" "${max_context}" "${mem_fraction}" "${probed_model}" "${probed_cpu_offload}"
        chmod 0600 "${backend_env_dir}/env"
    fi

    # 2. Deploy model catalog template expanded with USER_HOME
    if [ -f "${SCRIPT_DIR}/config/models/models_catalog.json" ]; then
        sed "s|__USER_HOME__|${USER_HOME}|g" "${SCRIPT_DIR}/config/models/models_catalog.json" > "${backend_env_dir}/models_catalog.json"
    fi

    # 3. Deploy systemd service profiles into backend_env_dir
    if compgen -G "${SCRIPT_DIR}/config/systemd/*.service" > /dev/null; then
        cp -f "${SCRIPT_DIR}"/config/systemd/*.service "${backend_env_dir}/"
    fi
    if compgen -G "${SCRIPT_DIR}/config/systemd/*.timer" > /dev/null; then
        cp -f "${SCRIPT_DIR}"/config/systemd/*.timer "${backend_env_dir}/"
    fi

    # 4. Deploy systemd user units into systemd_dest (~/.config/systemd/user)
    local units=(
        "opencode-server.service"
        "opencode-agent.slice"
        "opencode-colbert-reindex.service"
        "opencode-colbert-reindex.timer"
        "opencode-sglang-ornith-35b.service"
    )

    for u in "${units[@]}"; do
        if [ -f "${SCRIPT_DIR}/config/systemd/${u}" ]; then
            if [ -L "${systemd_dest}/${u}" ]; then
                rm -f "${systemd_dest}/${u}"
            fi
            cp -f "${SCRIPT_DIR}/config/systemd/${u}" "${systemd_dest}/${u}"
        fi
    done

    # Tune primary SGLang service with probed parameters
    if [ -n "$mem_fraction" ] && [ -n "$max_context" ] && [ -f "${systemd_dest}/opencode-sglang-ornith-35b.service" ]; then
        sed -i \
            "s|--mem-fraction-static [0-9.]*|--mem-fraction-static ${mem_fraction}|;s|Environment=\"SGLANG_CONTEXT_LENGTH=[0-9]*\"|Environment=\"SGLANG_CONTEXT_LENGTH=${max_context}\"|" \
            "${systemd_dest}/opencode-sglang-ornith-35b.service"
        sed -i \
            "s|--context-length [0-9]*\${SGLANG_CONTEXT_LENGTH}|--context-length \${SGLANG_CONTEXT_LENGTH}|" \
            "${systemd_dest}/opencode-sglang-ornith-35b.service"
    fi

    # 5. Reload systemd daemon if available
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user daemon-reload 2>/dev/null || true
    fi
    echo "  ✅ Deployed systemd user units to ${systemd_dest}/"
}

install_opencode_global() {
    local opencode_dest="${OPENCODE_HOME_DIR}"
    local opencode_tmpl="${SCRIPT_DIR}/templates/opencode"
    local legacy_launchers=("opencode-local" "opencode-architect-local" "opencode-worker-local" "opencode-reviewer-local" "opencode-sub-agent-local")
    local backend_env_dir="${BACKEND_DIR}"
    local systemd_dest="${SYSTEMD_USER_DIR}"

    echo "================================================================================"
    echo "🚀 INSTALLING OPENCODE HARNESS (GLOBAL MODE)"
    echo "   Target Dir    : ${opencode_dest}"
    echo "   Backend Dir   : ${backend_env_dir}"
    echo "   Systemd Dir   : ${systemd_dest}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would ensure ${backend_env_dir}/env exists for backend services"
        echo "  [DRY-RUN] Would probe GPU hardware via scripts/gpu_probe.sh and save to ${backend_env_dir}/gpu_profile.json"
        echo "  [DRY-RUN] Would update ${backend_env_dir}/env with PROBED_* sizing parameters"
        echo "  [DRY-RUN] Would prune legacy launchers in ${USER_HOME}/.local/bin/"
        echo "  [DRY-RUN] Would deploy agents/, commands/, skills/, tools/, rules/, plugins/, themes/, opencode.json to ${opencode_dest}/"
        echo "  [DRY-RUN] Would probe GPU hardware and deploy systemd user units to ${systemd_dest}/"
        return 0
    fi

    mkdir -p "${backend_env_dir}"
    if [ ! -f "${backend_env_dir}/env" ]; then
        cat << EOF > "${backend_env_dir}/env"
# OpenCode Backend Environment & Fallback Cloud API Configuration
# Gated model access token
HF_TOKEN=${HF_TOKEN:-}
# Remote Headless Server credentials (port 4096)
OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME:-}
OPENCODE_SERVER_PASSWORD=${OPENCODE_SERVER_PASSWORD:-}
OPENCODE_SERVER_PORT=4096
OPENCODE_SERVER_HOST=0.0.0.0
# Cloud API Fallback Keys
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
GEMINI_API_KEY=${GEMINI_API_KEY:-}
OPENAI_API_KEY=${OPENAI_API_KEY:-}
EOF
        chmod 0600 "${backend_env_dir}/env"
    else
        for var_name in HF_TOKEN ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY OPENCODE_SERVER_USERNAME OPENCODE_SERVER_PASSWORD; do
            val="${!var_name:-}"
            if [ -n "$val" ]; then
                if grep -sq "^${var_name}=$" "${backend_env_dir}/env"; then
                    sed -i "s|^${var_name}=$|${var_name}=${val}|" "${backend_env_dir}/env"
                elif ! grep -sq "^${var_name}=" "${backend_env_dir}/env"; then
                    printf '%s=%s\n' "$var_name" "$val" >> "${backend_env_dir}/env"
                fi
            fi
        done
        for fallback_var in ANTHROPIC_API_KEY GEMINI_API_KEY OPENAI_API_KEY; do
            if ! grep -sq "^${fallback_var}=" "${backend_env_dir}/env"; then
                printf '%s=\n' "$fallback_var" >> "${backend_env_dir}/env"
            fi
        done
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

    deploy_opencode_backend_and_units "${systemd_dest}" "${backend_env_dir}"
    echo "  ✅ Installed OpenCode 10-component hierarchy & systemd backend services to ${opencode_dest}/"
}

# --- LOCAL TARGET INSTALLERS --------------------------------------------------

install_agy_local() {
    local repo_path="$TARGET_REPO"
    local dest_orch="${repo_path}/.orchestration"
    local dest_agents="${repo_path}/.agents"
    local agy_tmpl="${SCRIPT_DIR}/templates/agy"

    echo "================================================================================"
    echo "🚀 INSTALLING AGY HARNESS (LOCAL REPOSITORY MODE)"
    echo "   Repository    : ${repo_path}"
    echo "   Orchestration : ${dest_orch}"
    echo "   Agents Link   : ${dest_agents}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would deploy operational assets to ${dest_orch}/"
        echo "  [DRY-RUN] Would create symlink ${dest_agents} -> .orchestration"
        echo "  [DRY-RUN] Ensure ${repo_path}/.gitignore ignores .agents/ and .orchestration/worktrees/"
        return 0
    fi

    if [ "$REINSTALL" = true ] && [ -d "$dest_orch" ]; then
        rm -rf "${dest_orch}/rules" "${dest_orch}/skills" "${dest_orch}/tools" "${dest_orch}/orchestration"
    fi

    mkdir -p "${dest_orch}/rules" "${dest_orch}/skills" "${dest_orch}/tools" "${dest_orch}/handoffs" "${dest_orch}/orchestration" "${dest_orch}/memory" "${dest_orch}/worktrees" "${dest_orch}/logs" "${dest_orch}/tmp"
    cp -rf "${agy_tmpl}/rules/"* "${dest_orch}/rules/"
    cp -rf "${agy_tmpl}/skills/"* "${dest_orch}/skills/"
    cp -rf "${agy_tmpl}/tools/"* "${dest_orch}/tools/"
    chmod +x "${dest_orch}/tools/"*.sh 2>/dev/null || true
    cp -rf "${agy_tmpl}/orchestration/"* "${dest_orch}/orchestration/"
    cp -f "${agy_tmpl}/handoffs/.gitkeep" "${dest_orch}/handoffs/.gitkeep"
    touch "${dest_orch}/memory/.gitkeep" "${dest_orch}/logs/.gitkeep" "${dest_orch}/tmp/.gitkeep"
    cp -f "${agy_tmpl}/GEMINI.md" "${dest_orch}/GEMINI.md"
    cp -f "${agy_tmpl}/AGENTS.md" "${dest_orch}/AGENTS.md"

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

    ensure_gitignore_entries "${repo_path}/.gitignore" ".agents/" ".opencode/" ".orchestration/worktrees/" ".orchestration/tmp/"
    echo "  ✅ Installed Antigravity operational assets to ${dest_orch}/ and linked ${dest_agents}"
}

install_claude_local() {
    local repo_path="$TARGET_REPO"
    local dest_claude="${repo_path}/.claude"
    local claude_tmpl="${SCRIPT_DIR}/templates/claude"

    echo "================================================================================"
    echo "🚀 INSTALLING CLAUDE CODE HARNESS (LOCAL REPOSITORY MODE)"
    echo "   Repository    : ${repo_path}"
    echo "   Claude Target : ${dest_claude}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would deploy agents/, skills/, rules/, settings/ to ${dest_claude}/"
        echo "  [DRY-RUN] Would merge ${dest_claude}/settings.json preserving custom user config"
        echo "  [DRY-RUN] Ensure ${repo_path}/.gitignore ignores .claude/"
        return 0
    fi

    mkdir -p "${dest_claude}/agents" "${dest_claude}/skills" "${dest_claude}/rules" "${dest_claude}/settings" "${dest_claude}/tools"
    cp -rf "${claude_tmpl}/agents/"* "${dest_claude}/agents/"
    cp -rf "${claude_tmpl}/skills/"* "${dest_claude}/skills/"
    cp -rf "${claude_tmpl}/rules/"* "${dest_claude}/rules/"
    cp -rf "${claude_tmpl}/tools/"* "${dest_claude}/tools/"
    chmod +x "${dest_claude}/tools/"*.sh "${dest_claude}/tools/"*.py 2>/dev/null || true
    cp -rf "${claude_tmpl}/settings/"* "${dest_claude}/settings/"
    cp -f "${claude_tmpl}/CLAUDE.md" "${dest_claude}/CLAUDE.md"

    local existing_user_settings="${dest_claude}/settings.json"
    if [ -f "$existing_user_settings" ] && [ ! -f "${existing_user_settings}.pre-harness.bak" ]; then
        cp -p "$existing_user_settings" "${existing_user_settings}.pre-harness.bak"
    fi

    python3 -m harness.installer.settings merge-claude \
        --user-settings "${dest_claude}/settings.json" \
        --template-settings "${claude_tmpl}/settings/core.json" \
        --output "${dest_claude}/settings.json"

    ensure_gitignore_entries "${repo_path}/.gitignore" ".claude/"
    echo "  ✅ Installed Claude Code local configuration to ${dest_claude}/"
}

install_opencode_local() {
    local repo_path="$TARGET_REPO"
    local dest_opencode="${repo_path}/.opencode"
    local opencode_tmpl="${SCRIPT_DIR}/templates/opencode"

    echo "================================================================================"
    echo "🚀 INSTALLING OPENCODE HARNESS (LOCAL REPOSITORY MODE)"
    echo "   Repository    : ${repo_path}"
    echo "   OpenCode Dir  : ${dest_opencode}"
    echo "   Dry Run       : ${DRY_RUN}"
    echo "================================================================================"

    if [ "$DRY_RUN" = true ]; then
        echo "  [DRY-RUN] Would deploy 10-component hierarchy to ${dest_opencode}/"
        echo "  [DRY-RUN] Ensure ${repo_path}/.gitignore ignores .opencode/"
        return 0
    fi

    mkdir -p "${dest_opencode}/agents" "${dest_opencode}/commands" "${dest_opencode}/skills" "${dest_opencode}/tools" "${dest_opencode}/rules" "${dest_opencode}/plugins" "${dest_opencode}/themes"
    cp -rf "${opencode_tmpl}/agents/"* "${dest_opencode}/agents/"
    cp -rf "${opencode_tmpl}/commands/"* "${dest_opencode}/commands/"
    cp -rf "${opencode_tmpl}/skills/"* "${dest_opencode}/skills/"
    cp -rf "${opencode_tmpl}/tools/"* "${dest_opencode}/tools/"
    chmod +x "${dest_opencode}/tools/"*.sh "${dest_opencode}/tools/"*.py 2>/dev/null || true
    cp -rf "${opencode_tmpl}/rules/"* "${dest_opencode}/rules/"
    cp -rf "${opencode_tmpl}/plugins/"* "${dest_opencode}/plugins/"
    cp -rf "${opencode_tmpl}/themes/"* "${dest_opencode}/themes/"
    cp -f "${opencode_tmpl}/opencode.json" "${dest_opencode}/opencode.json"
    cp -f "${opencode_tmpl}/tui.json" "${dest_opencode}/tui.json"
    cp -f "${opencode_tmpl}/AGENTS.md" "${dest_opencode}/AGENTS.md"

    if [ "$ENABLE_SYSTEMD" = true ]; then
        deploy_opencode_backend_and_units "${SYSTEMD_USER_DIR}" "${BACKEND_DIR}"
    fi

    ensure_gitignore_entries "${repo_path}/.gitignore" ".opencode/"
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
    ensure_gitignore_entries "${TARGET_REPO}/.gitignore" ".agents/" ".claude/" ".opencode/" ".orchestration/worktrees/" ".orchestration/tmp/"
}

# --- ACTION EXECUTORS ---------------------------------------------------------

run_install() {
    local recorded_roots=()
    local recorded_symlinks=()
    local recorded_files=()
    local manifest_file=""

    if [ "$MODE" = "local" ]; then
        manifest_file="${TARGET_REPO}/.orchestration/install_manifest.json"
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
                    for u in "opencode-server.service" "opencode-agent.slice" "opencode-colbert-reindex.service" "opencode-colbert-reindex.timer" "opencode-sglang-ornith-35b.service"; do
                        if [ -f "${SYSTEMD_USER_DIR}/${u}" ]; then
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
                    for u in "opencode-server.service" "opencode-agent.slice" "opencode-colbert-reindex.service" "opencode-colbert-reindex.timer" "opencode-sglang-ornith-35b.service"; do
                        if [ -f "${SYSTEMD_USER_DIR}/${u}" ]; then
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
        echo "🎉 Local Agent Harness installation complete!"
    else
        manifest_file="${USER_HOME}/.orchestration/install_manifest.json"
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
                for u in "opencode-server.service" "opencode-agent.slice" "opencode-colbert-reindex.service" "opencode-colbert-reindex.timer" "opencode-sglang-ornith-35b.service"; do
                    if [ -f "${SYSTEMD_USER_DIR}/${u}" ]; then
                        recorded_files+=("${SYSTEMD_USER_DIR}/${u}")
                    fi
                done
                ;;
            all)
                install_all_global
                recorded_roots+=("${USER_HOME}/.orchestration" "${GEMINI_CONFIG_DIR}/plugins/agent-harness" "${USER_HOME}/.claude" "${USER_HOME}/.config/opencode")
                recorded_symlinks+=("${USER_HOME}/.agents:${USER_HOME}/.orchestration" "${GEMINI_CONFIG_DIR}/plugins/agy-harness:${GEMINI_CONFIG_DIR}/plugins/agent-harness")
                for u in "opencode-server.service" "opencode-agent.slice" "opencode-colbert-reindex.service" "opencode-colbert-reindex.timer" "opencode-sglang-ornith-35b.service"; do
                    if [ -f "${SYSTEMD_USER_DIR}/${u}" ]; then
                        recorded_files+=("${SYSTEMD_USER_DIR}/${u}")
                    fi
                done
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
        echo "🎉 Global Agent Harness installation complete!"
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

    if [ -f "$manifest_file" ]; then
        local dry_flag=""
        if [ "$DRY_RUN" = true ]; then
            dry_flag="--dry-run"
        fi
        python3 -m harness.installer.manifest uninstall --manifest-path "$manifest_file" $dry_flag
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
                for u in "${systemd_user_dir}"/opencode-*.service "${systemd_user_dir}"/opencode-*.timer "${systemd_user_dir}"/opencode-*.slice; do
                    if [ -f "$u" ]; then
                        local unit_name="$(basename "$u")"
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

            # Safely restore pre-existing settings if backup exists
            if [ -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak" ]; then
                mv -f "${CLAUDE_HOME_DIR}/settings.json.pre-harness.bak" "${CLAUDE_HOME_DIR}/settings.json"
            fi

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
            # Safely restore pre-existing settings if backup exists
            if [ -f "${TARGET_REPO}/.claude/settings.json.pre-harness.bak" ]; then
                mv -f "${TARGET_REPO}/.claude/settings.json.pre-harness.bak" "${TARGET_REPO}/.claude/settings.json"
            fi
            # Only remove .agents if it is a symlink
            if [ -L "${TARGET_REPO}/.agents" ]; then
                rm -f "${TARGET_REPO}/.agents"
            fi
            # Restore pre-harness .agents directory if backed up
            if [ -d "${TARGET_REPO}/.agents.pre-harness.bak" ] && [ ! -e "${TARGET_REPO}/.agents" ]; then
                mv "${TARGET_REPO}/.agents.pre-harness.bak" "${TARGET_REPO}/.agents"
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
