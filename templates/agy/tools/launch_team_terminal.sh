#!/usr/bin/env bash
# ==============================================================================
# launch_team_terminal.sh - Headed Terminal & Team Session Launcher
#
# Launches an autonomous Team Orchestrator into an isolated terminal window/tab
# across Antigravity (agy), OpenCode (opencode), or Claude Code (claude).
#
# Usage:
#   launch_team_terminal.sh --harness [claude|agy|opencode] \
#                           --name <team_name> \
#                           --repo <repo_path> \
#                           --prompt <kickoff_prompt> \
#                           [--settings <settings_json>] \
#                           [--terminal [konsole|gnome-terminal|tmux|xterm|auto]]
# ==============================================================================
set -euo pipefail

HARNESS="claude"
TEAM_NAME="team-orchestrator"
REPO_PATH="$(pwd)"
PROMPT=""
SETTINGS_FILE=""
TERMINAL_EMULATOR="auto"

show_help() {
    sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --harness|-h)
            HARNESS="$2"
            shift 2
            ;;
        --name|-n)
            TEAM_NAME="$2"
            shift 2
            ;;
        --repo|-r)
            REPO_PATH="$2"
            shift 2
            ;;
        --prompt|-p)
            PROMPT="$2"
            shift 2
            ;;
        --settings|-s)
            SETTINGS_FILE="$2"
            shift 2
            ;;
        --terminal|-t)
            TERMINAL_EMULATOR="$2"
            shift 2
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

if [ -z "$PROMPT" ]; then
    echo "❌ Error: --prompt is required" >&2
    exit 1
fi

REPO_PATH="$(cd "$REPO_PATH" && pwd)"

# Construct harness invocation command
CMD_INNER=""
if [ "$HARNESS" = "claude" ]; then
    SETTINGS_ARG=""
    if [ -n "$SETTINGS_FILE" ] && [ -f "$SETTINGS_FILE" ]; then
        SETTINGS_ARG="--settings \"$SETTINGS_FILE\""
    fi
    CMD_INNER="cd \"$REPO_PATH\" && claude -n \"$TEAM_NAME\" $SETTINGS_ARG \"$PROMPT\"; exec bash"
elif [ "$HARNESS" = "opencode" ]; then
    CMD_INNER="cd \"$REPO_PATH\" && opencode \"$PROMPT\"; exec bash"
elif [ "$HARNESS" = "agy" ]; then
    CMD_INNER="cd \"$REPO_PATH\" && agy \"$PROMPT\"; exec bash"
else
    echo "❌ Error: Unknown harness: $HARNESS" >&2
    exit 1
fi

# Detect terminal emulator
detect_terminal() {
    if [ "$TERMINAL_EMULATOR" != "auto" ]; then
        echo "$TERMINAL_EMULATOR"
        return
    fi
    if command -v konsole >/dev/null 2>&1; then
        echo "konsole"
    elif command -v gnome-terminal >/dev/null 2>&1; then
        echo "gnome-terminal"
    elif [ -n "${TMUX:-}" ] && command -v tmux >/dev/null 2>&1; then
        echo "tmux"
    elif command -v kitty >/dev/null 2>&1; then
        echo "kitty"
    elif command -v alacritty >/dev/null 2>&1; then
        echo "alacritty"
    elif command -v xterm >/dev/null 2>&1; then
        echo "xterm"
    else
        echo "fallback"
    fi
}

TERM_TYPE="$(detect_terminal)"
echo "🚀 Launching $HARNESS team session '$TEAM_NAME' in $TERM_TYPE..."

# Environment sanitization wrapper to prevent child marker / socket inheritance
ENV_CLEAR=(
    env
    -u CLAUDECODE
    -u CLAUDE_CODE_CHILD_SESSION
    -u CLAUDE_CODE_ENTRYPOINT
    -u CLAUDE_CODE_EXECPATH
    -u CLAUDE_CODE_MESSAGING_SOCKET
    -u CLAUDE_CODE_MESSAGING_TOKEN
    -u CLAUDE_CODE_SESSION_ATTENDED
    -u CLAUDE_CODE_SESSION_ID
    -u CLAUDE_EFFORT
    -u CLAUDE_JOB_DIR
    -u CLAUDE_PID
)

case "$TERM_TYPE" in
    konsole)
        "${ENV_CLEAR[@]}" setsid konsole --new-tab -e bash -lic "$CMD_INNER" >/dev/null 2>&1 </dev/null &
        ;;
    gnome-terminal)
        "${ENV_CLEAR[@]}" setsid gnome-terminal --tab --title="$TEAM_NAME" -- bash -lic "$CMD_INNER" >/dev/null 2>&1 </dev/null &
        ;;
    tmux)
        "${ENV_CLEAR[@]}" tmux new-window -n "$TEAM_NAME" "bash -lic '$CMD_INNER'"
        ;;
    kitty)
        "${ENV_CLEAR[@]}" setsid kitty --title "$TEAM_NAME" bash -lic "$CMD_INNER" >/dev/null 2>&1 </dev/null &
        ;;
    alacritty)
        "${ENV_CLEAR[@]}" setsid alacritty --title "$TEAM_NAME" -e bash -lic "$CMD_INNER" >/dev/null 2>&1 </dev/null &
        ;;
    xterm)
        "${ENV_CLEAR[@]}" setsid xterm -T "$TEAM_NAME" -e bash -lic "$CMD_INNER" >/dev/null 2>&1 </dev/null &
        ;;
    *)
        echo "⚠️  No recognized GUI terminal or tmux detected. Running in detached background process..."
        "${ENV_CLEAR[@]}" nohup bash -lic "$CMD_INNER" > "team_${TEAM_NAME}.log" 2>&1 &
        echo "   Background PID: $!"
        ;;
esac

echo "✅ Launched team '$TEAM_NAME' successfully."
