#!/usr/bin/env bash
#
# test-vpn-egress.sh
#
# Validates the profile::platform::baseline::debian::virtual::k3s::vpn_egress_routing
# Puppet class on a given node, using disposable pods.
#
# Usage: ./test-vpn-egress.sh <node-name>
# Example: ./test-vpn-egress.sh delta
#
# Requires: kubectl context pointing at k3s-prod, manifest file
# vpn-test-pods.yaml in the same directory.

set -euo pipefail

NODE="${1:?Usage: $0 <node-name>}"
NAMESPACE="vpn"
MANIFEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST_DIR}/vpn-test-pods.yaml"
VPN_TEST_IP="10.58.0.59"
LXC_CONTAINER="zulu"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Derives the expected VPN egress /24 prefix from zulu's live wg0.conf,
# rather than a hardcoded value that goes stale whenever the VPN server
# changes. Egress IP isn't guaranteed to exactly match the WireGuard
# endpoint IP (observed one octet apart on PrivateVPN's Manchester
# server), so this compares on /24 prefix, not exact address.
derive_expected_vpn_prefix() {
  local endpoint_line endpoint_host endpoint_ip

  endpoint_line=$(lxc exec "${LXC_CONTAINER}" -- grep -i '^Endpoint' /etc/wireguard/wg0.conf) \
    || { echo "ERROR: could not read wg0.conf on ${LXC_CONTAINER}" >&2; return 1; }

  # Endpoint = host:port  ->  strip the port
  endpoint_host=$(echo "${endpoint_line}" | sed 's/^Endpoint *= *//' | cut -d: -f1)

  # If it's already an IP, dig +short returns nothing useful for it, so
  # check whether it's already dotted-quad first.
  if [[ "${endpoint_host}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    endpoint_ip="${endpoint_host}"
  else
    endpoint_ip=$(dig +short "${endpoint_host}" | head -n1)
  fi

  if [[ -z "${endpoint_ip}" ]]; then
    echo "ERROR: could not resolve VPN endpoint host/IP (${endpoint_host})" >&2
    return 1
  fi

  # First three octets only.
  echo "${endpoint_ip}" | cut -d. -f1-3
}

echo "=== Deriving expected VPN egress prefix from ${LXC_CONTAINER} ==="
EXPECTED_VPN_IP_PREFIX=$(derive_expected_vpn_prefix) || exit 1
echo "  Expected egress prefix: ${EXPECTED_VPN_IP_PREFIX}.x"
echo ""

cleanup() {
  echo "Cleaning up test pods..."
  kubectl delete pod vpn-test non-vpn-test -n "${NAMESPACE}" --ignore-not-found --wait=false
}
trap cleanup EXIT

echo "=== Deploying test pods to node: ${NODE} ==="
sed "s/NODE_NAME_PLACEHOLDER/${NODE}/g" "${MANIFEST}" | kubectl apply -f -

echo "Waiting for pods to be Running..."
kubectl wait --for=condition=Ready pod/vpn-test -n "${NAMESPACE}" --timeout=60s
kubectl wait --for=condition=Ready pod/non-vpn-test -n "${NAMESPACE}" --timeout=60s

echo ""
echo "=== Test 1: vpn-test explicit-bind egress goes via VPN ==="
VPN_IP=$(kubectl exec vpn-test -n "${NAMESPACE}" -- curl -s --interface "${VPN_TEST_IP}" ifconfig.me || echo "CURL_FAILED")
echo "  Result: ${VPN_IP}"
if [[ "${VPN_IP}" == "${EXPECTED_VPN_IP_PREFIX}"* ]]; then
  pass "vpn-test egress via ${VPN_TEST_IP} returned VPN IP"
else
  fail "vpn-test egress via ${VPN_TEST_IP} did NOT return expected VPN IP prefix (${EXPECTED_VPN_IP_PREFIX}.x)"
fi

echo ""
echo "=== Test 2: vpn-test default-route egress is unaffected (still home IP) ==="
DEFAULT_IP=$(kubectl exec vpn-test -n "${NAMESPACE}" -- curl -s ifconfig.me || echo "CURL_FAILED")
echo "  Result: ${DEFAULT_IP}"
if [[ "${DEFAULT_IP}" != "${EXPECTED_VPN_IP_PREFIX}"* && "${DEFAULT_IP}" != "CURL_FAILED" ]]; then
  pass "vpn-test default route still egresses normally (not via VPN)"
else
  fail "vpn-test default route unexpectedly matches VPN IP or curl failed - check default route wasn't altered unintentionally"
fi

echo ""
echo "=== Test 3: non-vpn-test is unaffected by the mangle rule ==="
NON_VPN_IP=$(kubectl exec non-vpn-test -n "${NAMESPACE}" -- curl -s ifconfig.me || echo "CURL_FAILED")
echo "  Result: ${NON_VPN_IP}"
if [[ "${NON_VPN_IP}" != "${EXPECTED_VPN_IP_PREFIX}"* && "${NON_VPN_IP}" != "CURL_FAILED" ]]; then
  pass "non-vpn-test egresses normally, unaffected by mangle rule"
else
  fail "non-vpn-test unexpectedly routed via VPN or curl failed - mangle rule may be over-matching"
fi

echo ""
echo "=== Test 4: DNS resolution from vpn-test ==="
if kubectl exec vpn-test -n "${NAMESPACE}" -- nslookup google.com >/dev/null 2>&1; then
  pass "DNS resolution works from vpn-test"
else
  fail "DNS resolution failed from vpn-test"
fi

echo ""
echo "=== Test 5: cluster-internal access from vpn-test ==="
if kubectl exec vpn-test -n "${NAMESPACE}" -- nslookup kubernetes.default >/dev/null 2>&1; then
  pass "Cluster-internal DNS (kubernetes.default) resolves from vpn-test"
else
  fail "Cluster-internal DNS resolution failed from vpn-test"
fi

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
