#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME=${1:-k3s-lxc}
IMAGE=ubuntu:24.04
PROFILE="default"
MEMORY="4GB"
CPUS="2"
K3S_ETC=/etc/rancher/k3s
K3S_CFGD=${K3S_ETC}/config.yaml.d
VIRTUAL_IP=10.58.0.60
API_DNS=api-${CLUSTER_NAME}.$(hostname -d)

HANDOVER_FILE=${HANDOVER_FILE:-bootstrap.env}

K3S_VERSION="v1.34.2+k3s1"
CLUSTER_TOKEN="super-secret-token"
[[ ! -f cluster_token ]] && openssl rand -hex 32 > cluster_token
CLUSTER_TOKEN=$(cat cluster_token)

# remote:container
CLUSTER=(
  "k3s-1"
  "k3s-2"
  "k3s-3"
)

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

  if ! lxc profile list "$remote:" | awk '{print $2}' | grep -qx k3s; then
    echo ">>> Creating k3s profile on $remote"
    lxc profile create "$remote:k3s"
  fi

  lxc profile set "$remote:k3s" security.privileged true
  lxc profile set "$remote:k3s" security.nesting true
  lxc profile set "$remote:k3s" raw.lxc "lxc.apparmor.profile=unconfined"
}

push_k3s_config() {
  local remote="$1"
  local name="$2"

  echo ">>> Pushing k3s config to ${remote}:${name}"

  # Push static config (creates dirs automatically)
  lxc file push -p -r k3s-config/* \
    "${remote}:${name}/${K3S_ETC}/"

  # Generate TLS SAN drop-in (dynamic per cluster)
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

copy_base_k3s_config() {
  local entry=$1
  lxc file push -pvr k3s-config/* ${REMOTE}:${NAME}/etc/rancher/k3s/
}

write_tls_san() {
  local ip=$1
  lxc exec ${FIRST_REMOTE}:${FIRST_NODE} -- bash -c "
cat > ${K3S_CFGD}/20-tls-san.yaml <<EOF
tls-san:
  - ${FIRST_IP}
EOF
"
}

echo ">>> Creating LXC containers on multiple LXD remotes"

for ENTRY in "${CLUSTER[@]}"; do
  parse_entry $ENTRY

  if lxc info "${REMOTE}:${NAME}" &>/dev/null; then
    echo ">>> ${REMOTE}:${NAME} already exists, skipping"
    continue
  fi

  echo ">>> Creating ${REMOTE}:${NAME}"

  ensure_k3s_profile $REMOTE

  lxc launch "$IMAGE" "$REMOTE:$NAME" \
    --profile "$PROFILE" --profile k3s \
    -c limits.memory="$MEMORY" \
    -c limits.cpu="$CPUS"

done

echo ">>> Waiting for DHCP addresses"

declare -A IPS

get_ip() {
  lxc list "$1:$2" --format csv -c 4 | head -1 | tr -d \" | cut -d' ' -f1
}

for ENTRY in "${CLUSTER[@]}"; do
  parse_entry $ENTRY

  while true; do
    IP=$(get_ip "$REMOTE" "$NAME")
    [[ -n "$IP" ]] && break
    sleep 2
  done

  IPS["$NAME"]="$IP"
  echo ">>> ${NAME} = ${IP}"
done

# First cluster entry is the initial k3s server
FIRST_ENTRY="${CLUSTER[0]}"
parse_entry "$FIRST_ENTRY"
FIRST_NODE=$NAME
FIRST_REMOTE=$REMOTE
FIRST_IP="${IPS[$FIRST_NODE]}"

cat > "${HANDOVER_FILE}" <<EOF
FIRST_NODE=${FIRST_NODE}
FIRST_REMOTE=${FIRST_REMOTE}
FIRST_IP=${FIRST_IP}
CLUSTER="${CLUSTER[*]}"
EOF

echo ">>> Wrote bootstrap handover to ${HANDOVER_FILE}"

echo ">>> Creating k3s config on ${FIRST_REMOTE}:${FIRST_NODE}"
push_k3s_config ${FIRST_REMOTE} ${FIRST_NODE}

echo ">>> Installing k3s on ${FIRST_REMOTE}:${FIRST_NODE}"

lxc exec "${FIRST_REMOTE}:${FIRST_NODE}" -- bash -c "
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -s - server \
  --cluster-init \
  --token ${CLUSTER_TOKEN}
"

# TODO add back in when cilium migration testing complete
  #--disable flannel \
  #--disable-network-policy \
  #--disable-kube-proxy \

for ENTRY in "${CLUSTER[@]}"; do
  parse_entry $ENTRY

  [[ "$NAME" == "$FIRST_NODE" ]] && continue

  echo ">>> Creating k3s config on ${REMOTE}:${NAME}"
  push_k3s_config ${REMOTE} ${NAME}

  echo ">>> Joining ${REMOTE}:${NAME}"

  lxc exec "${REMOTE}:${NAME}" -- bash -c "
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=${K3S_VERSION} sh -s - server \
  --server https://${FIRST_IP}:6443 \
  --token ${CLUSTER_TOKEN}
"
done

# TODO add back in when cilium migration testing complete
  #--disable flannel \
  #--disable-network-policy \
  #--disable-kube-proxy \

echo ">>> k3s multi-LXD bootstrap complete"
