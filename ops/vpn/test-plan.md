# VPN Egress Migration — Status & Plan

## Goal
Replace gluetun + pod-gateway with simpler node-level VPN egress via a dedicated WireGuard LXC gateway (`zulu`), as a stepping stone toward Cilium's `EgressGatewayPolicy`.

## Architecture

**Gateway container (`zulu`)**
- LXC container, Puppet class `profile::app::wireguard` (`site-modules/profile/manifests/app/wireguard.pp`)
- Runs `wg-quick`, connected to PrivateVPN (currently Manchester server — London had handshake failures, unrelated to config)
- LAN IP: `10.58.0.24`
- PostUp/PostDown masquerade + `ip_forward` already configured for `10.58.0.0/24`

**Multus NAD: `vpn-gateway`**
- Namespace: `network`
- Range: `10.58.0.50–59` (matches existing network.md-documented production Multus range)
- Static IPs assigned:
  - `dispatcharr` → `10.58.0.50` (IPTV — stays on VPN)
  - `qbittorrent` → `10.58.0.51`
  - `sabnzbd` → `10.58.0.52`

**Node-side routing (Puppet)**
- Class: `profile::platform::baseline::debian::virtual::k3s::vpn_egress_routing`
- Has `$enabled` flag (default `true`) — set `false` to cleanly tear down mark/rule/route/table-name
- Mechanism: iptables mangle mark (100) on source `10.58.0.50-59` → `ip rule` → custom table `vpn_egress` (100) → default route via `10.58.0.24`
- **Not yet applied to any node except test runs on delta**
- **Not yet persistent across reboot** — needs a systemd oneshot unit or `iptables-persistent`, and the `$enabled=false` branch will eventually need to also remove that persistence mechanism

**Pod-side routing (still to finalize before rollout)**
- Plain node-level routing only affects traffic explicitly sourced from the pod's static IP — apps must bind to it, or:
- **Preferred approach:** init container (`NET_ADMIN`) per pod, sets explicit routes for pod CIDR (`10.42.0.0/16`) and service CIDR (`10.43.0.0/16`) via `eth0`, then sets pod's real default route via `net1` → `10.58.0.1` (edge router). Avoids relying on each app supporting a bind-IP setting.
- Cleanly removable later — delete the init container, delete the `vpn-gateway` Multus annotation, once Cilium's egress gateway takes over.

## Excluded from VPN (via pod-gateway, not moved namespace)
`prowlarr`, `radarr`, `sonarr` stay in the `vpn` namespace (GUI-configured URL dependencies) but opt out of gluetun routing individually:

```yaml
controllers:
  <app-name>:
    pod:
      labels:
        setGateway: "false"
```

(pod-gateway/gateway-admission-controller default is `gatewayDefault: true` — whole namespace routed unless a pod explicitly opts out via `setGateway`.)

## Testing assets (already produced)
- `vpn-test-pods.yaml` — disposable `vpn-test` (attached to `vpn-gateway` NAD, `10.58.0.59`) and `non-vpn-test` pods, node name templated via `NODE_NAME_PLACEHOLDER`
- `test-vpn-egress.sh <node-name>` — deploys both pods, derives expected VPN IP prefix live from `zulu`'s `wg0.conf` (via `lxc exec zulu`), runs egress/DNS/cluster-access checks, cleans up
- **Test order:** apply Puppet class to one node (delta) → run script → roll to charlie, golf, hotel

## Known gaps
1. Reboot persistence for node-side iptables/ip rule/ip route — not yet built
2. Pod-side routing approach (init container) — designed but not yet added to any real pod
3. pod-gateway's gluetun kill-switch NetworkPolicy is **not actually applying** (`kubectl get networkpolicy -n vpn` returns empty) — likely a chart-version key mismatch (`addons.vpn.networkPolicy` vs. newer `networkPolicies`). **Deliberately left unfixed** — zulu's design is fail-closed by default (no fallback route), so this becomes moot once migration completes. Acceptable only if the gluetun transition period stays short.
4. `network.md` still describes the `10.58.0.50–59` range generically — needs updating once `vpn-gateway` NAD is live in gitops

## Migration order from here
1. Roll Puppet routing class to all 4 k3s nodes
2. Add init-container pod-side routing; migrate `sabnzbd` first, validate
3. Migrate `qbittorrent`, then `dispatcharr`
4. Remove gluetun sidecar/pod-gateway config from those three deployments
5. Decommission the pod-gateway/gluetun HelmRelease entirely
6. Update `network.md`
7. Later: move dispatcharr/qbittorrent/sabnzbd into `media` namespace (alongside Plex) — routing is namespace-agnostic (IP-based), no changes needed to the mechanism itself; check any `media` NetworkPolicies for needed egress exceptions
8. Long-term: Cilium `EgressGatewayPolicy` referencing zulu replaces the manual mangle/rule/route mechanism; remove the Puppet class, `vpn-gateway` NAD/annotations, and pod init containers at that point

## Key reference values
- zulu LAN IP: `10.58.0.24`
- VPN provider: PrivateVPN (Manchester server active as of 2026-08-26; account previously suspended, now resolved)
- Puppet gateway manifest: `site-modules/profile/manifests/app/wireguard.pp`
- New Puppet routing class: `profile::platform::baseline::debian::virtual::k3s::vpn_egress_routing`
- k3s pod CIDR: `10.42.0.0/16` · service CIDR: `10.43.0.0/16` (confirmed via node specs, no explicit flags)
