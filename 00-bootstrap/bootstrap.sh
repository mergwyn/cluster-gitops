#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Bootstrap k3s cluster with environment-specific configuration
# -----------------------------------------------------------------------------

ENV="${ENV:-dev}"
BOOTSTRAP_ENV="env.${ENV}"
TOKEN_FILE="${TOKEN_FILE:-.cluster-token}"

if [[ ! -f "$BOOTSTRAP_ENV" ]]; then
  echo "ERROR: missing environment file $BOOTSTRAP_ENV"
  exit 1
fi

# Load cluster-specific environment
source "$BOOTSTRAP_ENV"

CONFIG="$HOME/.kube/clusters/$CLUSTER_NAME.yaml"
KUBECTL="kubectl --kubeconfig $CONFIG"
HELMFILE="helmfile --kubeconfig $CONFIG --environment ${ENV}"
VIRTUAL_IP=$(dig +short ${API_DNS})
K3S_CFGD=/etc/rancher/k3s/config.yaml.d
ARGOCD_NS=argocd

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

parse_entry() {
  local entry="$1"
  if [[ "$entry" == *:* ]]; then
    REMOTE="${entry%%:*}"
    NAME="${entry##*:}"
  else
    REMOTE="local"
    NAME="$entry"
  fi
}

ensure_k3s_profile() {
  local remote="$1"
  profile="$remote:k3s"
  if ! lxc profile list "$remote:" | awk '{print $2}' | grep -qx k3s; then
    echo ">>> Creating k3s profile on $remote"
    lxc profile create "$profile"
    lxc profile edit "$profile" <<EOT
name: $profile
config:
  limits.memory.swap: "false"
  linux.kernel_modules: overlay,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,xt_conntrack,nf_conntrack,ip_vs,vxlan
  raw.lxc: |
    lxc.apparmor.profile = unconfined
    lxc.cgroup.devices.allow = a
    lxc.mount.auto = "proc:rw sys:rw"
    lxc.cap.drop =
  security.nesting: "true"
  security.privileged: "true"
devices:
  kmsg:
    path: /dev/kmsg
    type: unix-char
EOT
  fi
}

get_ip() {
  lxc list "$1:$2" --format csv -c 4 | head -1 | tr -d \" | cut -d' ' -f1
}

push_k3s_config() {
  local remote="$1"
  local name="$2"

  echo ">>> Pushing k3s config to ${remote}:${name}"

  lxc file push -p -r k3s-config/* "${remote}:${name}/etc/rancher/k3s/"

  # TLS SAN drop-in
  {
    echo "cat > ${K3S_CFGD}/20-tls-san.yaml <<EOF"
    echo "tls-san:"
    echo "  - ${API_DNS}"
    echo "  - ${VIRTUAL_IP}"
    for node in "${!IPS[@]}"; do
      echo "  - ${IPS[$node]}"
    done
    echo EOF
  } | lxc exec "${remote}:${name}" -- bash -s -e -
}

set_context() {
  # First node is initial k3s server
  FIRST_ENTRY="${CLUSTER_NODES[0]}"
  parse_entry "$FIRST_ENTRY"
  FIRST_NODE="$NAME"
  FIRST_REMOTE="$REMOTE"
  #FIRST_IP="${IPS[$FIRST_NODE]}"
  #VIRTUAL_IP="$FIRST_IP"
}

generate_bases() {
# the cluster wide environements file is designed to be run at a different
# level in the hierarchy. Adjust for this location.
  {
    sed -e 's:../../..:../..:' ../clusters/environments.yaml
    cat <<!

helmDefaults:
  cleanupOnFail: true
  wait: true
  waitForJobs: true
!
  } > environments.yaml
}

# -----------------------------------------------------------------------------
# Stages
# -----------------------------------------------------------------------------

bootstrap_cluster() {
  echo ">>> Bootstrapping k3s cluster ($ENV)"

  # Generate cluster token if missing
  [[ ! -f "$TOKEN_FILE" ]] && openssl rand -hex 32 > "$TOKEN_FILE"
  CLUSTER_TOKEN=$(cat "$TOKEN_FILE")

  echo ">>> Creating LXC containers"
  declare -A IPS

  for ENTRY in "${CLUSTER_NODES[@]}"; do
    parse_entry "$ENTRY"
    if lxc info "${REMOTE}:${NAME}" &>/dev/null; then
      echo ">>> ${REMOTE}:${NAME} already exists, skipping"
      continue
    fi
    echo ">>> Creating ${REMOTE}:${NAME}"
    ensure_k3s_profile "$REMOTE"
    lxc launch "$IMAGE" "$REMOTE:$NAME" --profile "$PROFILE" --profile k3s -c limits.memory="$MEMORY" -c limits.cpu="$CPUS"
  done

  echo ">>> Waiting for IP addresses"
  for ENTRY in "${CLUSTER_NODES[@]}"; do
    parse_entry "$ENTRY"
    while true; do
      IP=$(get_ip "$REMOTE" "$NAME")
      [[ -n "$IP" ]] && break
      sleep 2
    done
    IPS["$NAME"]="$IP"
    echo ">>> $NAME = $IP"
  done

  set_context
  FIRST_IP="${IPS[$FIRST_NODE]}"
  VIRTUAL_IP="$FIRST_IP"

  echo ">>> Pushing k3s config to first node"
  push_k3s_config "$FIRST_REMOTE" "$FIRST_NODE"

  echo ">>> Installing k3s server on first node"
  lxc exec "$FIRST_REMOTE:$FIRST_NODE" -- bash -c "
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -s - server \
  --cluster-init \
  --token ${CLUSTER_TOKEN}
"

  echo ">>> Waiting for API server..."
  until lxc exec "$FIRST_REMOTE:$FIRST_NODE" -- /usr/local/bin/k3s kubectl get nodes >/dev/null 2>&1; do
    sleep 2
  done

  # Join other nodes
  for ENTRY in "${CLUSTER_NODES[@]}"; do
    parse_entry "$ENTRY"
    [[ "$NAME" == "$FIRST_NODE" ]] && continue
    echo ">>> Joining ${REMOTE}:${NAME}"
    push_k3s_config "$REMOTE" "$NAME"
    lxc exec "$REMOTE:$NAME" -- bash -c "
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -s - server \
  --server https://${FIRST_IP}:6443 \
  --token ${CLUSTER_TOKEN}
"
  done

  # Load kubeconfig
  echo ">>> Loading kubeconfig"
  mkdir -p "$(dirname "$CONFIG")"
  lxc exec "$FIRST_REMOTE:$FIRST_NODE" -- cat /etc/rancher/k3s/k3s.yaml \
    | sed "s/127.0.0.1/$FIRST_IP/" > "$CONFIG"

  echo ">>> Running kubeconfig hygiene"
  ./scripts/kubeconfig-hygiene.sh "$CONFIG" "$CLUSTER_NAME" "$ARGOCD_NS"
  chmod 600 "$CONFIG"
  echo ">>> kubeconfig written to $CONFIG"
}

install_apps() {
  set_context
  echo ">>> Waiting for nodes to be Ready"
  ${KUBECTL} wait --for=condition=Ready nodes --all --timeout=600s

  echo ">>> Creating ArgoCD namespace and secrets"
  ${KUBECTL} create ns "$ARGOCD_NS" --dry-run=client -o yaml | ${KUBECTL} apply -f -
  ${KUBECTL} create secret generic argocd-age-secret-keys \
    --namespace="$ARGOCD_NS" \
    --from-file=/home/gary/.config/sops/age/keys.txt \
    --dry-run=client -o yaml | ${KUBECTL} apply -f -

  echo ">>> Syncing Helm releases"
  generate_bases
  ${HELMFILE} sync

  echo ">>> Applying AppSet for environment: $ENV"

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

  kubectl apply -f <(
    yq eval '
      .spec.generators[0].git.revision = strenv(CURRENT_BRANCH) |
      .spec.template.spec.source.targetRevision = strenv(CURRENT_BRANCH) |
      .spec.template.spec.source.plugin.env[0].value = strenv(ENV)
    ' cluster-gitops-handover.yaml
  )
}


clean_cluster() {
  set_context
  echo ">>> Cleaning $CLUSTER_NAME LXC cluster"

  for node in "${CLUSTER_NODES[@]}"; do
    if lxc info "$node" &>/dev/null; then
      echo "$node is active, stopping and deleting"
      lxc stop "$node"
      lxc delete "$node"
    else
      echo "$node is not running"
    fi
  done
  rm -f .cluster-token
}

# -----------------------------------------------------------------------------
# CLI dispatch
# -----------------------------------------------------------------------------

case "${1:-}" in
  cluster) bootstrap_cluster ;;
  install) install_apps ;;
  clean)   clean_cluster ;;
  bases)   generate_bases ;;
  all)     bootstrap_cluster; install_apps ;;
  *)
    echo "Usage: $0 {cluster|install|clean|bases|all}"
    exit 1
    ;;
esac
