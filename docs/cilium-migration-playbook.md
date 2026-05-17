# Cilium Migration Playbook
## k3s -- Flannel to Cilium (Dev Rehearsal)

**Scope:** CNI replacement only. Egress Gateway, WireGuard integration, and
bootstrap updates are out of scope.

**Environment:**
- 3-node control plane LXC cluster, no workloads
- Vanilla k3s flannel, k3s v1.34.6
- Pod CIDR: 10.42.0.0/16 (k3s default)
- Service CIDR: 10.43.0.0/16 (k3s default)
- Dev cluster VIP: 10.58.0.60

**Strategy:**
- Phase A: Install Cilium alongside kube-proxy via Cilium CLI (fast iteration)
- Phase B: Once stable, disable kube-proxy as a separate change
- Phase C: Once values are proven, codify into helmfile for the prod path

---

## Prerequisites

```bash
# Install cilium CLI on workstation
brew install cilium-cli

# Confirm correct cluster context
kubectl config current-context
kubectl get nodes

# Snapshot LXC VMs before starting -- easy rollback
lxc snapshot create <each-dev-node> pre-cilium-migration
```

All nodes should be `Ready`, all kube-system pods `Running`. Don't start on a
degraded cluster.

---

## Phase 1 -- Disable Flannel (All Nodes)

Add config drop-in on **every node** before restarting any of them. This
ensures consistency when nodes come back up.

Create `/etc/rancher/k3s/config.yaml.d/50-cilium.yaml` on each node:

```yaml
# Disable built-in flannel CNI
flannel-backend: none

# Disable built-in network policy controller (Cilium replaces this)
disable-network-policy: true
```

Notice we are **not** touching kube-proxy yet -- that comes in Phase B.

---

## Phase 2 -- Rolling Node Restart with Interleaved Cilium Install

**DNS continuity matters.** Your CoreDNS deployment uses `topologySpreadConstraints`
with `maxSkew: 1` on hostname -- one replica per node. If we restart all three
nodes before installing Cilium, all three CoreDNS pods lose networking and DNS
goes fully down. With this revised ordering, we install Cilium after two nodes
are restarted, so CoreDNS on those two recovers before the third node is touched.

Phase 2 flow:

```
Restart node 1  ->  restart node 2  ->  install Cilium  ->  restart node 3
```

### Step 1 -- Restart node 1

```bash
kubectl cordon <node-1>
ssh <node-1> 'systemctl restart k3s'
# Wait for Ready (60-90s)
kubectl get nodes -w
kubectl uncordon <node-1>
```

CoreDNS on node 1 will be `CrashLoopBackOff` or `ContainerCreating` -- expected.
Cluster DNS is degraded but functional via the 2 remaining replicas.

### Step 2 -- Restart node 2

```bash
kubectl cordon <node-2>
ssh <node-2> 'systemctl restart k3s'
kubectl get nodes -w
kubectl uncordon <node-2>
```

Now 2/3 CoreDNS pods are broken. The remaining replica on node 3 is still
serving DNS -- quorum-style protection. Don't touch node 3 yet.

### Step 3 -- Install Cilium (jump to Phase A below)

Install Cilium **now**, with node 3 still on flannel. Cilium agents will
deploy on nodes 1 and 2 (where flannel is disabled) and provide networking.
CoreDNS pods on those nodes will recover within ~30s of cilium-agent landing.

After Cilium agents are running on nodes 1 and 2 and their CoreDNS pods are
back to `Running`, return here for step 4.

Confirm before proceeding:

```bash
# CoreDNS should be 2/3 Ready (node 3 will still be Running on flannel)
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide

# Both restarted nodes should have cilium-agent Running
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
```

### Step 4 -- Restart node 3

Only now, with DNS protected by 2 working CoreDNS replicas on Cilium:

```bash
kubectl cordon <node-3>
ssh <node-3> 'systemctl restart k3s'
kubectl get nodes -w
kubectl uncordon <node-3>
```

Within ~30s, cilium-agent should also land on node 3 and CoreDNS there will
recover. You should now have 3/3 CoreDNS replicas Running on Cilium.

### Confirm flannel is gone from all nodes

```bash
for node in <node-1> <node-2> <node-3>; do
  echo "=== $node ==="
  ssh $node 'ls /run/flannel/ 2>&1 || echo "no flannel dir (good)"'
  ssh $node 'ip link show cni0 2>&1 | head -1 || echo "no cni0 (good)"'
  ssh $node 'ip link show flannel.1 2>&1 | head -1 || echo "no flannel.1 (good)"'
done
```

If flannel interfaces persist on any node, reboot that node -- they don't
always clean up on `systemctl restart`.

---

## Phase A -- Install Cilium (called during Phase 2 Step 3)

This phase runs **between Step 2 and Step 4 of Phase 2** -- after 2 nodes are
on no-CNI and before the third is restarted.

```bash
cilium install \
  --version 1.16.7 \
  --set k8sServiceHost=10.58.0.60 \
  --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList='{10.42.0.0/16}' \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set operator.replicas=1
```

**Note: `kubeProxyReplacement` is NOT set.** This means Cilium installs in
"probe" mode and lets kube-proxy continue handling services. Cilium owns the
pod networking, kube-proxy owns service routing.

### Validation

```bash
# Wait for Cilium to be ready
cilium status --wait

# All nodes should report Ready, all pods Running
kubectl get nodes
kubectl get pods -A

# CoreDNS should recover within ~30s of cilium-agent starting on each node
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Verify Cilium-managed networking
kubectl exec -n kube-system <coredns-pod> -- nslookup kubernetes.default
```

### Connectivity test

```bash
cilium connectivity test
```

This deploys temporary test pods across nodes and runs ~40 checks. Allow
10-15 minutes. All should pass before moving on.

### Hubble check

```bash
# Port-forward Hubble UI
cilium hubble ui

# Or use the CLI
cilium hubble port-forward &
hubble observe --since 5m
```

You should see flows being captured. This is the observability win -- when
something breaks later, you can see exactly what's being dropped and why.

**Stop here and let it bake.** Run for at least a few hours, ideally a day,
before moving to Phase B. Watch `cilium status` and `kubectl get pods -A`
for any flapping.

---

## Phase B -- Remove kube-proxy

Only proceed after Phase A is stable.

### Step 1 -- Update Cilium to take over kube-proxy duties

```bash
cilium upgrade \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=10.58.0.60 \
  --set k8sServicePort=6443
```

This tells Cilium to start handling service routing in addition to pod
networking. kube-proxy is still running but Cilium's BPF programs will
intercept service traffic first.

Wait for rollout:

```bash
cilium status --wait
kubectl rollout status -n kube-system ds/cilium
```

### Step 2 -- Verify Cilium is handling services

```bash
# Should report "True" for kubeProxyReplacement
kubectl -n kube-system exec ds/cilium -- cilium status | grep KubeProxyReplacement
```

### Step 3 -- Disable kube-proxy in k3s

Update `/etc/rancher/k3s/config.yaml.d/50-cilium.yaml` on every node:

```yaml
flannel-backend: none
disable-network-policy: true
disable-kube-proxy: true
```

Then rolling restart again (same procedure as Phase 2):

```bash
# Per node
kubectl cordon <node>
ssh <node> 'systemctl restart k3s'
# wait for Ready
kubectl uncordon <node>
```

### Step 4 -- Confirm kube-proxy is gone

```bash
# No kube-proxy pods should exist
kubectl get pods -A | grep kube-proxy
# Expected: no resources

# No kube-proxy iptables chains
ssh <node> 'iptables -t nat -L | grep KUBE-SERVICES'
# Expected: empty
```

### Step 5 -- Re-run connectivity test

```bash
cilium connectivity test
```

All checks should still pass with kube-proxy gone.

---

## Phase C -- Codify into Helmfile

Once Phase B is stable, capture the working configuration into your existing
Cilium helmfile under `kubernetes/*platform/network/cilium/`.

Key values to encode (translating from the CLI flags):

```yaml
# values.yaml.gotmpl or equivalent
kubeProxyReplacement: true
k8sServiceHost: 10.58.0.60      # dev VIP; parametrise per environment
k8sServicePort: 6443

ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 10.42.0.0/16

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

Commit and push. ArgoCD will pick up the Cilium app, but since Cilium is
already installed with matching config, the reconciliation should be a
no-op (or close to it). Confirm:

```bash
kubectl get application -n argocd cilium
# Should show Synced / Healthy
```

If ArgoCD wants to make destructive changes, **pause sync** and reconcile
the values until it shows no diff before allowing it to sync.

---

## Rollback

### Phase A rollback (Cilium installed, kube-proxy still up)

```bash
# Uninstall Cilium
cilium uninstall

# Restore flannel on each node -- remove the drop-in
ssh <node> 'rm /etc/rancher/k3s/config.yaml.d/50-cilium.yaml'
ssh <node> 'systemctl restart k3s'
```

### Phase B rollback (kube-proxy already removed)

This is harder -- getting kube-proxy back requires:

1. Remove `disable-kube-proxy: true` from k3s config
2. Restart k3s on each node
3. Then proceed with Phase A rollback

For the rehearsal, easier path: revert to the LXC snapshots you took at the
start.

---

## What to Watch Out For

**LXC kernel module visibility.** Cilium uses eBPF heavily. The host kernel
needs `bpf` and `cgroup2` available, and LXC containers need permission to
access them. If `cilium status` shows BPF mount errors, the LXC profile
needs:

```
lxc.apparmor.profile = unconfined
lxc.cap.drop =
linux.kernel_modules = ip_tables,ip6_tables,netlink_diag,nf_nat,overlay
security.privileged = true
```

These are the same kinds of caps your k3s LXC containers already need --
worth verifying before starting.

**Cilium 1.16 vs 1.17.** As of Cilium 1.17 the install flags changed
slightly for `kubeProxyReplacement` -- the values went from string
("strict"/"partial"/"disabled") to boolean. The playbook uses 1.16 syntax.
If you go newer, check the upgrade notes.

**Connectivity test failures on LXC.** Some of the connectivity test checks
involve host-network pods and may fail in LXC environments with restricted
caps. If `cilium connectivity test` fails on host-network checks but
in-cluster pod-to-pod traffic works fine, it's usually safe to proceed.

---

## Prod Migration Notes (Out of Scope but Worth Noting)

When you eventually run this on prod:

- **Snapshot every node first** -- you have charlie, delta, echo etc.
- **MetalLB will be affected.** Cilium has its own LB IPAM (L2 announcements
  via `CiliumL2AnnouncementPolicy`). Decide before prod migration whether
  to keep MetalLB or move to Cilium's L2 -- the latter is cleaner but more
  change at once.
- **Pod restart impact.** Existing pods will lose networking briefly when
  flannel goes away and Cilium takes over. With real workloads this means
  service disruption -- plan a maintenance window.
- **kube-vip / VIP handling.** Your prod VIP (10.58.0.30) is provided by
  kube-vip and should be unaffected, but worth confirming kube-vip still
  binds correctly after Cilium takes over.
