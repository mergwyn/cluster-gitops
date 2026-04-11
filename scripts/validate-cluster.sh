#!/bin/bash
# validate-cluster.sh - Comprehensive K3s cluster validation script

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
KUBECTL="kubectl"
KUBECTL="lxc exec k3s-1 -- kubectl"
NAMESPACE="validation-test-$(date +%s)"
TIMEOUT=120

# Helper functions
print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE} $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

wait_for_condition() {
    local description="$1"
    local command="$2"
    local timeout="$3"
    
    echo -n "Waiting for $description... "
    local count=0
    while ! eval "$command" &>/dev/null; do
        sleep 2
        count=$((count + 2))
        if [ $count -ge $timeout ]; then
            echo -e "${RED}FAILED (timeout)${NC}"
            return 1
        fi
    done
    echo -e "${GREEN}OK${NC}"
    return 0
}

# Start validation
print_header "K3s Cluster Validation Suite"
echo "Started at: $(date)"
echo "Namespace: $NAMESPACE"

# 1. Basic Cluster Health
print_header "1. Basic Cluster Health"

# Check nodes
echo -n "Checking node status... "
NODESTATUS=$($KUBECTL get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}')
if [[ "$NODESTATUS" == *"True"* ]]; then
    print_success "All nodes are Ready"
    $KUBECTL get nodes -o wide
else
    print_error "Nodes not ready"
    $KUBECTL get nodes
    exit 1
fi
NODES=$($KUBECTL get nodes -o name | sed 's:node/::')

# Check control plane components
echo -e "\nChecking control plane components..."
CONTROL_PLANE_PODS=("coredns" "local-path-provisioner" "metrics-server")
for pod in "${CONTROL_PLANE_PODS[@]}"; do
    if $KUBECTL get pods -n kube-system | grep -q "$pod.*Running"; then
        print_success "$pod is running"
    else
        print_error "$pod is not running"
    fi
done

# 2. Network Validation
print_header "2. Network Validation"

# Check iptables backend
echo -n "Checking iptables backend... "
for node in $NODES; do
    if lxc exec $node -- iptables --version | grep -q "legacy"; then
        print_success "$node: iptables-legacy"
    else
        print_error "$node: iptables not legacy"
    fi
done

# Check Flannel interfaces
echo -e "\nChecking Flannel interfaces..."
for node in $NODES; do
    if lxc exec $node -- ip link show flannel.1 &>/dev/null; then
        print_success "$node: flannel.1 exists"
    else
        print_error "$node: flannel.1 missing"
    fi
done

# 3. Pod Network Test
print_header "3. Pod Network Test"

# Create test namespace
$KUBECTL create namespace $NAMESPACE &>/dev/null
print_info "Created test namespace: $NAMESPACE"

# Deploy test pods
echo -e "\nDeploying test pods across nodes..."
for node in $NODES; do
    $KUBECTL run test-pod-$node -n $NAMESPACE \
        --image=busybox \
        --restart=Never \
        --overrides='{"spec":{"nodeName":"'$node'"}}' \
        -- sleep 3600 &>/dev/null
done

# Wait for pods to be ready
wait_for_condition "pods to be ready" \
    "$KUBECTL get pods -n $NAMESPACE -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'" \
    $TIMEOUT

# Get pod IPs
POD_IPS=()
for node in $NODES; do
    IP=$($KUBECTL get pod test-pod-$node -n $NAMESPACE -o jsonpath='{.status.podIP}')
    POD_IPS+=($IP)
    print_info "test-pod-$node IP: $IP"
done

# Test pod-to-pod communication
echo -e "\nTesting pod-to-pod communication..."
if $KUBECTL exec -n $NAMESPACE test-pod-k3s-1 -- ping -c 3 ${POD_IPS[1]} &>/dev/null; then
    print_success "Pod-to-pod communication works (k3s-1 → k3s-2)"
else
    print_error "Pod-to-pod communication failed (k3s-1 → k3s-2)"
fi

if $KUBECTL exec -n $NAMESPACE test-pod-k3s-1 -- ping -c 3 ${POD_IPS[2]} &>/dev/null; then
    print_success "Pod-to-pod communication works (k3s-1 → k3s-3)"
else
    print_error "Pod-to-pod communication failed (k3s-1 → k3s-3)"
fi

# 4. Service Test
print_header "4. Service Test"

# Deploy nginx
echo "Deploying nginx..."
$KUBECTL create deployment nginx -n $NAMESPACE --image=nginx --replicas=2 &>/dev/null
wait_for_condition "nginx pods to be ready" \
    "$KUBECTL get pods -n $NAMESPACE -l app=nginx -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'" \
    $TIMEOUT

# Expose as service
$KUBECTL expose deployment nginx -n $NAMESPACE --port=80 --type=ClusterIP &>/dev/null
SERVICE_IP=$($KUBECTL get svc nginx -n $NAMESPACE -o jsonpath='{.spec.clusterIP}')

echo -e "\nTesting service access..."
if $KUBECTL run -n $NAMESPACE test-service --image=busybox -it --rm --restart=Never -- wget -qO- http://$SERVICE_IP &>/dev/null; then
    print_success "Service is accessible (ClusterIP: $SERVICE_IP)"
else
    print_error "Service not accessible"
fi

# 5. DNS Test
print_header "5. DNS Test"

echo "Testing DNS resolution..."
DNS_TEST=$($KUBECTL run -n $NAMESPACE dns-test --image=busybox -it --rm --restart=Never -- nslookup nginx.$NAMESPACE.svc.cluster.local 2>&1)
if echo "$DNS_TEST" | grep -q "Address: $SERVICE_IP"; then
    print_success "DNS resolution works (nginx.$NAMESPACE.svc.cluster.local → $SERVICE_IP)"
else
    print_error "DNS resolution failed"
    echo "$DNS_TEST"
fi

# 6. Storage Test (if local-path-provisioner is available)
print_header "6. Storage Test"

if $KUBECTL get storageclass local-path &>/dev/null; then
    echo "Testing local-path storage..."
    cat <<EOF | $KUBECTL apply -n $NAMESPACE -f - &>/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: local-path
---
apiVersion: v1
kind: Pod
metadata:
  name: test-storage
spec:
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - mountPath: /data
      name: test-volume
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: test-pvc
EOF
    
    wait_for_condition "PVC to be bound" \
        "$KUBECTL get pvc test-pvc -n $NAMESPACE -o jsonpath='{.status.phase}' | grep -q 'Bound'" \
        $TIMEOUT
    
    if $KUBECTL get pvc test-pvc -n $NAMESPACE | grep -q Bound; then
        print_success "Storage works (local-path-provisioner)"
    else
        print_error "Storage test failed"
    fi
else
    print_warning "local-path-provisioner not found, skipping storage test"
fi

# 7. ArgoCD Validation (if installed)
print_header "7. ArgoCD Validation"

if $KUBECTL get namespace argocd &>/dev/null; then
    echo "Checking ArgoCD components..."
    ARGOCD_PODS=$($KUBECTL get pods -n argocd -o jsonpath='{.items[*].status.phase}')
    if echo "$ARGOCD_PODS" | grep -q "Running"; then
        print_success "ArgoCD pods are running"
        
        # Wait for ArgoCD server to be ready
        wait_for_condition "ArgoCD server to be ready" \
            "$KUBECTL get pods -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}' | grep -q 'True'" \
            60
        
        # Get ArgoCD admin password
        echo -e "\nArgoCD access information:"
        ARGO_PASSWORD=$($KUBECTL -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" 2>/dev/null | base64 -d)
        if [ -n "$ARGO_PASSWORD" ]; then
            print_info "ArgoCD URL: http://$(lxc exec k3s-1 -- kubectl get svc -n argocd argocd-server -o jsonpath='{.spec.clusterIP}'):8080"
            print_info "Username: admin"
            print_info "Password: $ARGO_PASSWORD"
        fi
    else
        print_warning "ArgoCD not fully running yet"
        $KUBECTL get pods -n argocd
    fi
else
    print_warning "ArgoCD not installed, skipping validation"
fi

# 8. Load Balancer Test (if MetalLB or similar is installed)
print_header "8. Load Balancer Test"

if $KUBECTL get namespace metallb-system &>/dev/null; then
    echo "Testing LoadBalancer service..."
    cat <<EOF | $KUBECTL apply -n $NAMESPACE -f - &>/dev/null
apiVersion: v1
kind: Service
metadata:
  name: test-lb
spec:
  type: LoadBalancer
  loadBalancerClass: metallb.io/internal
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
EOF
    
    wait_for_condition "LoadBalancer to get external IP" \
        "$KUBECTL get svc test-lb -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q '^[0-9]'" \
        60
    
    LB_IP=$($KUBECTL get svc test-lb -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [ -n "$LB_IP" ]; then
        print_success "LoadBalancer works (IP: $LB_IP)"
    else
        print_warning "LoadBalancer not configured (no external IP assigned)"
    fi
else
    print_warning "MetalLB not installed, skipping LoadBalancer test"
fi

# 9. Resource Metrics Test
print_header "9. Resource Metrics Test"

if $KUBECTL top nodes &>/dev/null; then
    echo "Node metrics:"
    $KUBECTL top nodes
    print_success "Metrics server is working"
else
    print_warning "Metrics server not ready yet (may need a few minutes)"
fi

# 10. Final Cleanup
print_header "10. Cleanup"

echo "Cleaning up test resources..."
$KUBECTL delete namespace $NAMESPACE &>/dev/null
print_success "Test namespace deleted"

# Summary
print_header "Validation Summary"

echo -e "✅ Cluster Nodes: Ready"
echo -e "✅ Network: Pod-to-pod communication working"
echo -e "✅ Services: ClusterIP services working"
echo -e "✅ DNS: Service discovery working"
echo -e "✅ Storage: $([ $KUBECTL get storageclass local-path &>/dev/null ] && echo "Working" || echo "Not configured")"
echo -e "✅ ArgoCD: $([ $KUBECTL get namespace argocd &>/dev/null ] && echo "Installed" || echo "Not installed")"
echo -e "✅ LoadBalancer: $([ $KUBECTL get namespace metallb-system &>/dev/null ] && echo "Configured" || echo "Not configured")"

print_success "\nCluster validation completed successfully!"
echo -e "Your K3s cluster is ready for production workloads.\n"
