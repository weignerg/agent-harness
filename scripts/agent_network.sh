#!/usr/bin/env bash
# ==============================================================================
# scripts/agent_network.sh - provision the isolated agent sandbox network.
#   --print-rules   print the nftables ruleset (no privileges needed)
#   --create        create the container network (podman or docker) [--dry-run]
#   --destroy       remove it                                        [--dry-run]
# ==============================================================================
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF="${AGENT_NET_CONF:-${REPO_DIR}/config/network/agent-bridge.conf}"
# shellcheck disable=SC1090
source "$CONF"
ACTION=""; DRY=0
for a in "$@"; do case "$a" in
    --print-rules|--create|--destroy) ACTION="$a" ;; --dry-run) DRY=1 ;;
    *) echo "Usage: $0 --print-rules|--create|--destroy [--dry-run]" >&2; exit 2 ;; esac; done
[ -n "$ACTION" ] || { echo "Usage: $0 --print-rules|--create|--destroy [--dry-run]" >&2; exit 2; }

for p in $ALLOWED_PORTS; do
    [[ "$p" =~ ^[0-9]+$ ]] || { echo "invalid port: $p" >&2; exit 1; }
    [ "$p" != "45431" ] || { echo "port 45431 is retired and must not be exposed" >&2; exit 1; }
done

rules() {
    local ports="${ALLOWED_PORTS// /, }"
    cat <<EOF
table inet opencode_agent {
  chain forward {
    type filter hook forward priority 0; policy accept;
    iifname "${BRIDGE_IFACE}" oifname != "${BRIDGE_IFACE}" drop
    oifname "${BRIDGE_IFACE}" iifname != "${BRIDGE_IFACE}" ct state established,related accept
    oifname "${BRIDGE_IFACE}" drop
  }
  chain input {
    type filter hook input priority 0; policy accept;
    iifname "${BRIDGE_IFACE}" ct state established,related accept
    iifname "${BRIDGE_IFACE}" ip daddr ${GATEWAY} tcp dport { ${ports} } accept
    iifname "${BRIDGE_IFACE}" drop
  }
}
EOF
}

engine() { for e in podman docker; do command -v "$e" >/dev/null 2>&1 && { echo "$e"; return; }; done; return 1; }
run() { if [ "$DRY" = 1 ]; then echo "[DRY-RUN] $*"; else "$@"; fi; }

case "$ACTION" in
    --print-rules) rules ;;
    --create)
        E="$(engine)" || { [ "$DRY" = 1 ] && E=podman || { echo "no podman/docker found" >&2; exit 1; }; }
        run "$E" network create --driver bridge --internal --subnet "$SUBNET" --gateway "$GATEWAY" \
            -o "com.docker.network.bridge.name=${BRIDGE_IFACE}" "$NETWORK_NAME"
        echo "Apply host rules with: $0 --print-rules | sudo nft -f -" ;;
    --destroy)
        E="$(engine)" || { [ "$DRY" = 1 ] && E=podman || { echo "no podman/docker found" >&2; exit 1; }; }
        run "$E" network rm "$NETWORK_NAME" ;;
esac
