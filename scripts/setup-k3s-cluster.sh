#!/usr/bin/env bash
#
# setup-k3s-cluster.sh — Easily set up a k3s cluster.
#
# Modes:
#   server   Install a k3s control-plane node (first node, or an HA member).
#   agent    Join this machine to an existing cluster as a worker.
#   uninstall Remove k3s from this machine.
#
# Examples:
#   # First control-plane node
#   ./setup-k3s-cluster.sh server
#
#   # First control-plane node with a fixed token and disabling traefik
#   K3S_TOKEN=mysecret ./setup-k3s-cluster.sh server --disable traefik
#
#   # HA control-plane node joining an existing server
#   ./setup-k3s-cluster.sh server --server https://10.0.0.1:6443 --token <node-token>
#
#   # Worker node
#   ./setup-k3s-cluster.sh agent --server https://10.0.0.1:6443 --token <node-token>
#
#   # Tear it down
#   ./setup-k3s-cluster.sh uninstall
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (override via env or flags)
# ---------------------------------------------------------------------------
MODE=""
K3S_VERSION="${K3S_VERSION:-}"          # e.g. v1.30.2+k3s2 ; empty = latest stable
K3S_URL="${K3S_URL:-}"                  # https://<server>:6443 ; required for agent / HA join
K3S_TOKEN="${K3S_TOKEN:-}"              # cluster token; auto-generated for a fresh server
NODE_NAME="${NODE_NAME:-$(hostname -s)}"
CLUSTER_INIT="${CLUSTER_INIT:-}"        # set to 1 to bootstrap an embedded-etcd HA cluster
WRITE_KUBECONFIG_MODE="${WRITE_KUBECONFIG_MODE:-0644}"
EXTRA_ARGS=()

log()  { printf '\033[1;34m[k3s]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[k3s]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[k3s]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || usage 1

MODE="$1"; shift
case "$MODE" in
    server|agent|uninstall) ;;
    -h|--help) usage 0 ;;
    *) die "Unknown mode '$MODE' (expected: server | agent | uninstall)" ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      K3S_VERSION="$2"; shift 2 ;;
        --server|--url) K3S_URL="$2"; shift 2 ;;
        --token)        K3S_TOKEN="$2"; shift 2 ;;
        --node-name)    NODE_NAME="$2"; shift 2 ;;
        --cluster-init) CLUSTER_INIT=1; shift ;;
        -h|--help)      usage 0 ;;
        --)             shift; EXTRA_ARGS+=("$@"); break ;;
        *)              EXTRA_ARGS+=("$1"); shift ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "k3s runs on Linux only. This host is $(uname -s)."

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Run as root or install sudo."
    SUDO="sudo"
fi

need_curl() { command -v curl >/dev/null 2>&1 || die "curl is required but not installed."; }

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "$MODE" == "uninstall" ]]; then
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        log "Removing k3s server..."
        $SUDO /usr/local/bin/k3s-uninstall.sh
    elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
        log "Removing k3s agent..."
        $SUDO /usr/local/bin/k3s-agent-uninstall.sh
    else
        warn "No k3s uninstall script found; nothing to do."
    fi
    log "Done."
    exit 0
fi

# ---------------------------------------------------------------------------
# Build installer environment
# ---------------------------------------------------------------------------
need_curl

INSTALL_ENV=()
[[ -n "$K3S_VERSION" ]] && INSTALL_ENV+=("INSTALL_K3S_VERSION=$K3S_VERSION")

INSTALL_EXEC=()

if [[ "$MODE" == "server" ]]; then
    INSTALL_EXEC+=("server")
    INSTALL_EXEC+=("--node-name" "$NODE_NAME")
    INSTALL_EXEC+=("--write-kubeconfig-mode" "$WRITE_KUBECONFIG_MODE")

    if [[ -n "$K3S_URL" ]]; then
        # Joining an existing control plane as an HA member.
        [[ -n "$K3S_TOKEN" ]] || die "--token is required when joining an existing server with --server."
        INSTALL_ENV+=("K3S_URL=$K3S_URL")
        INSTALL_ENV+=("K3S_TOKEN=$K3S_TOKEN")
        INSTALL_EXEC+=("--server" "$K3S_URL")
    elif [[ -n "$CLUSTER_INIT" ]]; then
        # Bootstrapping a fresh HA cluster with embedded etcd.
        INSTALL_EXEC+=("--cluster-init")
        [[ -n "$K3S_TOKEN" ]] && INSTALL_ENV+=("K3S_TOKEN=$K3S_TOKEN")
    else
        # Single-node / first server.
        [[ -n "$K3S_TOKEN" ]] && INSTALL_ENV+=("K3S_TOKEN=$K3S_TOKEN")
    fi
else
    # agent
    [[ -n "$K3S_URL" ]]   || die "agent mode requires --server https://<server>:6443"
    [[ -n "$K3S_TOKEN" ]] || die "agent mode requires --token <node-token>"
    INSTALL_ENV+=("K3S_URL=$K3S_URL")
    INSTALL_ENV+=("K3S_TOKEN=$K3S_TOKEN")
    INSTALL_EXEC+=("agent" "--node-name" "$NODE_NAME")
fi

INSTALL_EXEC+=("${EXTRA_ARGS[@]:-}")

# Trim a possible trailing empty element from EXTRA_ARGS default expansion.
CLEAN_EXEC=()
for a in "${INSTALL_EXEC[@]}"; do [[ -n "$a" ]] && CLEAN_EXEC+=("$a"); done

log "Mode:        $MODE"
log "Node name:   $NODE_NAME"
[[ -n "$K3S_VERSION" ]] && log "Version:     $K3S_VERSION" || log "Version:     latest stable"
[[ -n "$K3S_URL" ]]     && log "Join URL:    $K3S_URL"
log "Exec args:   ${CLEAN_EXEC[*]}"

# ---------------------------------------------------------------------------
# Run the official installer
# ---------------------------------------------------------------------------
log "Downloading and running the k3s installer..."
curl -sfL https://get.k3s.io | \
    $SUDO env "${INSTALL_ENV[@]}" INSTALL_K3S_EXEC="${CLEAN_EXEC[*]}" sh -

# ---------------------------------------------------------------------------
# Post-install
# ---------------------------------------------------------------------------
if [[ "$MODE" == "server" ]]; then
    log "Waiting for the node to become Ready..."
    for _ in $(seq 1 60); do
        if $SUDO k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; then
            break
        fi
        sleep 2
    done

    $SUDO k3s kubectl get nodes -o wide || true

    KUBECONFIG_SRC="/etc/rancher/k3s/k3s.yaml"
    KUBECONFIG_DST="${HOME}/.kube/config-k3s-${NODE_NAME}"
    if [[ -r "$KUBECONFIG_SRC" ]]; then
        mkdir -p "${HOME}/.kube"
        $SUDO cat "$KUBECONFIG_SRC" > "$KUBECONFIG_DST"
        chmod 600 "$KUBECONFIG_DST"
        log "Kubeconfig written to: $KUBECONFIG_DST"
        log "Use it with:  export KUBECONFIG=$KUBECONFIG_DST"
        log ""
        log "If you'll reach the API from another machine, replace 127.0.0.1"
        log "in that file with this host's reachable IP address."
    fi

    NODE_TOKEN_FILE="/var/lib/rancher/k3s/server/node-token"
    if $SUDO test -r "$NODE_TOKEN_FILE"; then
        log ""
        log "Join more nodes with this token:"
        printf '    '
        $SUDO cat "$NODE_TOKEN_FILE"
        log "Example (worker):"
        log "    ./setup-k3s-cluster.sh agent --server https://<this-host-ip>:6443 --token <token-above>"
    fi
else
    log "Agent installed. Check it from a control-plane node with: kubectl get nodes"
fi

log "Done."
