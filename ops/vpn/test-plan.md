# VPN Egress Migration — Status & Plan (v2 — simplified architecture)

## Goal
Replace gluetun + pod-gateway with simpler VPN egress via a dedicated WireGuard LXC gateway (`zulu`), as a stepping stone toward Cilium's `EgressGatewayPolicy`.

## Architecture (corrected/simplified)

**Gateway container (`zulu`)**
- LXC container, Puppet class `profile::app::wireguard` (`site-modules/profile/manifests/app/wireguard.pp`)
- Runs `wg-quick`, connected to PrivateVPN — currently Manchester server (`uk-man.pvdata.host`). London had handshake failures unrelated to config; account was also found suspended at one point and has since been resolved.
- LAN IP: `10.58.0.24`
- PostUp/PostDown masquerade (`10.58.0.0/24` → `wg0`) + `ip_forward` already configured — no changes needed here

**Multus NAD: `vpn-gateway`**
- Namespace: `network`
- Type: `ipvlan`, mode `l2`, master `br0`
- Range: `10.58.0.50–59`
- Static IPs assigned:
  - `dispatcharr` → `10.58.0.50` (IPTV — stays on VPN)
  - `qbittorrent` → `10.58.0.51`
  - `sabnzbd` → `10.58.0.52`
  - `.59` reserved permanently for test pods

**Routing — pod-level only, no node-side config**

Key architectural finding: `ipvlan` in L2 mode bridges the pod's second interface (`net1`) directly to the physical LAN, bypassing the host node's own IP routing/netfilter stack entirely. This means **node-level iptables/ip-rule/ip-route interception cannot see this traffic at all** — an original design assumption that turned out to be wrong, confirmed by testing. The fix is simpler than the original plan: control routing entirely from inside the pod via an init container.

**Per-pod init container** (added to each VPN-routed workload):
```yaml
initContainers:
  - name: vpn-routing
    image: nicolaka/netshoot
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
    command:
      - sh
      - -c
      - |
        set -e
        GW=$(ip route show default | awk '{print $3; exit}')
        ip route add 10.43.0.0/16 via "${GW}" dev eth0
        ip route del default
        ip route add default via 10.58.0.24 dev net1
        ip route show
```
- `GW` captured dynamically (varies per node — each node's pod subnet has a different CNI gateway)
- Pod CIDR (`10.42.0.0/16`) route already added automatically by CNI — no need to add it again
- Service CIDR (`10.43.0.0/16`) needs an explicit route **via the CNI gateway**, not just `dev eth0` — an on-link route with no `via` fails silently (service IPs aren't real L2 neighbours)
- Default route points **directly at zulu** (`10.58.0.24`), not the real LAN edge router — this is the key correction from the original plan

**No pinning needed** — since all routing logic lives in the pod spec itself, it works identically regardless of which node the pod schedules onto.

**No persistence work needed** — unlike the abandoned node-level approach (which would have needed systemd/iptables-persistent to survive reboots), init containers run on every pod start by construction. Nothing to keep in sync with a reboot.

## Abandoned: node-level Puppet class
- `profile::platform::baseline::debian::virtual::k3s::vpn_egress_routing` — **not used**, does not work for ipvlan-attached
