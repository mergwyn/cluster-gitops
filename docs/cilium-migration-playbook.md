
# Cilium Migration Playbook

## k3s - Flannel to Cilium (Dev Rehearsal)

**Scope:** CNI replacement only. Egress Gateway, WireGuard integration,
kube-proxy replacement, and bootstrap updates are out of scope. kube-proxy
will continue running alongside Cilium and can be addressed later once the
dev cluster is stable.

**Environment:**

- 3-node control plane k3s VMs on LXC, no workloads
- Vanilla k3s flannel, k3s v1.34.6
- Pod CIDR: 10.42.0.0/16 (k3s default)
- Service CIDR: 10.43.0.0/16 (k3s default)
- Dev cluster VIP: 10.58.0.60
- Multus, MetalLB, and kube-vip installed
- Cilium CLI v0.19.2, will install Cilium v1.19.1

**Strategy:**

- Phase 1: Snapshot, prep config drop-ins
- Phase 2: Rolling node restart with interleaved Cilium install (preserves DNS)
- Phase 3: Validate
- Phase 4: Codify into helmfile

-----

## Prerequisites

```bash
# Confirm Cilium CLI is installed and on the expected version
cilium version

# Confirm correct cluster context
kubectl config current-context
kubectl get nodes

# Snapshot the k3s VMs before starting - easy rollback
for vm in k3s-1 k3s-2 k3s-3; do
  lxc snapshot create $vm pre-cilium-migration
done
```

All nodes should be `Ready`, all kube-system pods `Running`. Don't start
on a degraded cluster.

-----

## Phase 1 - Prepare k3s Config Drop-ins

Create a local file `50-cilium.yaml`:

```yaml
# Disable built-in flannel CNI
flannel-backend: none

# Disable built-in network policy controller (Cilium replaces this)
disable-network-policy: true
```

Push to all nodes before restarting any of them, so the config is
consistent when they come back up:

```bash
for vm in k3s-1 k3s-2 k3s-3; do
  lxc file push 50-cilium.yaml \
    $vm/etc/rancher/k3s/config.yaml.d/50-cilium.yaml
done
```

Note: we are not touching kube-proxy. It will continue to run alongside
Cilium until explicitly disabled in a future migration.

-----

## Phase 2 - Rolling Node Restart with Interleaved Cilium Install

DNS continuity matters. Your CoreDNS deployment uses
`topologySpreadConstraints` with `maxSkew: 1` on hostname - one replica
per node. If we restart all three nodes before installing Cilium, all
three CoreDNS pods lose networking and DNS goes fully down. With this
ordering, we install Cilium after two nodes are restarted, so CoreDNS on
those two recovers before the third node is touched.

Flow:

```
Restart k3s-1  ->  restart k3s-2  ->  install Cilium  ->  restart k3s-3
```

### Step 1 - Restart k3s-1

```bash
kubectl cordon k3s-1
lxc exec k3s-1 -- systemctl restart k3s
# Wait for Ready (60-90s)
kubectl get nodes -w
kubectl uncordon k3s-1
```

CoreDNS on k3s-1 will be `CrashLoopBackOff` or `ContainerCreating` -
expected. Cluster DNS is degraded but functional via the 2 remaining
replicas.

### Step 2 - Restart k3s-2

```bash
kubectl cordon k3s-2
lxc exec k3s-2 -- systemctl restart k3s
kubectl get nodes -w
kubectl uncordon k3s-2
```

Now 2/3 CoreDNS pods are broken. The remaining replica on k3s-3 is still
serving DNS. Don't touch k3s-3 yet.

### Step 3 - Install Cilium

With k3s-1 and k3s-2 on no-CNI and k3s-3 still on flannel:

```bash
cilium install \
  --version 1.19.1 \
  --set k8sServiceHost=10.58.0.60 \
  --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.42.0.0/16}' \
  --set cni.binPath=/var/lib/rancher/k3s/data/current/bin \
  --set cni.confPath=/var/lib/rancher/k3s/agent/etc/cni/net.d \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1
```

Why those CNI path flags matter: k3s places CNI binaries and configs in
non-standard locations under `/var/lib/rancher/k3s/`. Without these flags,
Cilium installs but pods stay in `ContainerCreating` because the kubelet
can't find the CNI plugin. This is a very common gotcha.

`kubeProxyReplacement` is deliberately NOT set. Cilium installs without
taking over service routing, and kube-proxy continues handling services.

Wait for Cilium to be ready:

```bash
cilium status --wait
```

Cilium agents will deploy on k3s-1 and k3s-2 (where flannel is disabled)
and provide networking. CoreDNS pods on those nodes should recover within
~30s of cilium-agent landing.

Confirm before proceeding:

```bash
# CoreDNS should be 2/3 Ready (k3s-3 will still be Running on flannel)
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

# k3s-1 and k3s-2 should have cilium-agent Running
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
```

### Step 4 - Restart k3s-3

Only now, with DNS protected by 2 working CoreDNS replicas on Cilium:

```bash
kubectl cordon k3s-3
lxc exec k3s-3 -- systemctl restart k3s
kubectl get nodes -w
kubectl uncordon k3s-3
```

Within ~30s, cilium-agent should also land on k3s-3 and CoreDNS there
will recover. You should now have 3/3 CoreDNS replicas Running on Cilium.

### Step 5 - Confirm flannel is gone from all nodes

```bash
for vm in k3s-1 k3s-2 k3s-3; do
  echo "=== $vm ==="
  lxc exec $vm -- ls /run/flannel/ 2>&1 || echo "no flannel dir (good)"
  lxc exec $vm -- ip link show cni0 2>&1 | head -1 || echo "no cni0 (good)"
  lxc exec $vm -- ip link show flannel.1 2>&1 | head -1 || echo "no flannel.1 (good)"
done
```

If flannel interfaces persist on any node, reboot that node - they don't
always clean up on `systemctl restart`.

-----

## Phase 3 - Validate

### Basic health

```bash
# All nodes Ready
kubectl get nodes

# All pods Running
kubectl get pods -A

# Cilium specifically
cilium status
```

### DNS resolution from a pod

```bash
kubectl exec -n kube-system <coredns-pod> -- nslookup kubernetes.default
```

### Multus

Multus runs as a meta-plugin on top of the primary CNI. When flannel was
removed, Multus's default delegate config under
`/var/lib/rancher/k3s/agent/etc/cni/net.d/` may still reference flannel.
Confirm Multus is now delegating to Cilium:

```bash
# Check CNI conf files on a node - should see cilium, not flannel
lxc exec k3s-1 -- ls /var/lib/rancher/k3s/agent/etc/cni/net.d/

# Confirm NetworkAttachmentDefinitions still resolve
kubectl get net-attach-def -A
```

If Multus is misbehaving, the fix is usually to delete the old flannel
conf file under `net.d/` and let Multus re-read the current state. On
restart, k3s and Cilium should manage this automatically, but worth
checking.

### MetalLB

MetalLB operates at L2 and doesn't depend on the CNI - should be
unaffected:

```bash
kubectl get pods -n metallb-system
# All Running

# Test a LoadBalancer service is still answering
kubectl get svc -A | grep LoadBalancer
# Curl one of the External-IPs from a workstation
```

### kube-vip

The API VIP (10.58.0.60) is owned by kube-vip. Confirm it still binds:

```bash
ping 10.58.0.60
kubectl get nodes  # this call uses the VIP
```

### Connectivity test

```bash
cilium connectivity test
```

This deploys temporary test pods across nodes and runs ~40 checks. Allow
10-15 minutes. Some host-network checks may fail in restricted
environments; if pod-to-pod and pod-to-service checks pass, you're in
good shape.

### Hubble

```bash
cilium hubble port-forward &
hubble observe --since 5m
```

You should see flows being captured. This is your new debugging tool -
the main observability win from the migration.

Stop here and let it bake. Run for at least a few hours, ideally a day,
before declaring success. Watch `cilium status` for any flapping.

-----

## Phase 4 - Codify into Helmfile

Once Phase 3 is stable, capture the working configuration into your
existing Cilium helmfile under `kubernetes/*platform/network/cilium/`.

Key values to encode (translating from the CLI flags):

```yaml
# values.yaml.gotmpl or equivalent
k8sServiceHost: 10.58.0.60       # dev VIP; parametrise per environment
k8sServicePort: 6443

ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.42.0.0/16

cni:
  binPath: /var/lib/rancher/k3s/data/current/bin
  confPath: /var/lib/rancher/k3s/agent/etc/cni/net.d

hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true

operator:
  replicas: 1   # dev; bump to 2 for prod
```

Then remove the Cilium exclusion from your dev appset:

```yaml
# In cluster-gitops-handover.yaml, REMOVE this exclusion:
- path: kubernetes/*platform/network/cilium/app.yaml
  exclude: true
```

Commit and push. ArgoCD will pick up the Cilium app. Since Cilium is
already installed with matching config, reconciliation should be a no-op
or close to it. Confirm:

```bash
kubectl get application -n argocd cilium
# Should show Synced / Healthy
```

If ArgoCD wants to make destructive changes, pause sync and reconcile
the values until it shows no diff before allowing it to sync.

-----

## Rollback

### Easy path - LXC snapshots

```bash
for vm in k3s-1 k3s-2 k3s-3; do
  lxc stop $vm
  lxc snapshot restore $vm pre-cilium-migration
  lxc start $vm
done
```

### Manual rollback (after partial migration)

```bash
# Uninstall Cilium
cilium uninstall

# Remove the k3s config drop-in
for vm in k3s-1 k3s-2 k3s-3; do
  lxc exec $vm -- rm /etc/rancher/k3s/config.yaml.d/50-cilium.yaml
  lxc exec $vm -- systemctl restart k3s
done
```

-----

## What to Watch Out For

**eBPF requirements.** Cilium uses eBPF heavily. Since you're running k3s
in VMs (not containers) on LXC, the eBPF requirements are met by the
guest kernel directly - no LXC capability juggling needed.

**Connectivity test failures on host-network.** Some `cilium connectivity
test` checks involve host-network pods and may fail in restricted
environments. If pod-to-pod and pod-to-service checks pass, the failures
are typically benign.

**Multus delegate.** Worth checking the CNI conf files under
`/var/lib/rancher/k3s/agent/etc/cni/net.d/` if NetworkAttachmentDefinitions
stop working - stale flannel conf can confuse Multus.

**Cilium 1.19 vs older.** As of 1.17, `kubeProxyReplacement` is boolean
not string. This playbook targets 1.19.1 (current default for cilium-cli
0.19.x). Not relevant in this migration since we're not enabling kube-proxy
replacement.

-----

## Future Work (Out of Scope)

After dev is stable, follow-up migrations to consider:

1. **kube-proxy replacement** - have Cilium take over service routing
   then disable kube-proxy in k3s. Done as a separate change with its
   own bake period.

2. **Cilium Egress Gateway** - route selected pods through your yankee/zulu
   WireGuard containers.

3. **CiliumNetworkPolicy** - default-deny for VPN-routed pods as a
   killswitch.

4. **Cilium L2 announcements** - potentially replace MetalLB with
   Cilium's built-in LB IPAM. More disruption, but consolidates tools.

5. **Bootstrap update** - integrate Cilium into the cluster bootstrap so
   future rebuilds install Cilium from the start.
