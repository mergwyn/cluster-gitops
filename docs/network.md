# Network Addressing Intent

## Scope

This document defines the **authoritative intent** for IPv4 address allocation within the `10.58.0.0/24` network. It exists to:

* Prevent IP overlap
* Make purpose and ownership of ranges obvious
* Support current production workloads
* Allow future expansion (test clusters, new services)

This file should be treated as the **source of truth** for network layout decisions.

---

## Topology Overview

* Single IPv4 subnet: `10.58.0.0/24`
* Mixed environment:

  * Physical hosts
  * LXC hosts
  * Kubernetes (k3s) production cluster
  * Planned LXC-based test cluster
  * IoT and DHCP devices

---

## Address Allocation

### Core Infrastructure

| Range         | Purpose                                                        |
| ------------- | -------------------------------------------------------------- |
| `10.58.0.1–9` | Network infrastructure (router, DNS, switches, management IPs) |

---

### Servers (Static)

| Range           | Purpose                                               |
| --------------- | ----------------------------------------------------- |
| `10.58.0.10–19` | Physical servers (including **production k3s nodes**) |
| `10.58.0.20–29` | Infrastructure LXC servers (AD, Samba, core services) |

---

### Kubernetes – Production

| Range           | Purpose                                                            |
| --------------- | ------------------------------------------------------------------ |
| `10.58.0.30–39` | **Production Kubernetes** virtual IPs and MetalLB LoadBalancer IPs |

Notes:

* kube-vip currently uses `10.58.0.32`
* MetalLB IP pools must **exclude** kube-vip addresses
* This range is reserved exclusively for production Kubernetes networking

---

### Kubernetes – Test / Experimental (LXC)

| Range           | Purpose                                                       |
| --------------- | ------------------------------------------------------------- |
| `10.58.0.60–79` | LXC-based test Kubernetes clusters and experimental workloads |

Intent:

* Must never overlap with production IPs
* Firewall rules may explicitly restrict access to production ranges
* Test clusters should use distinct Pod CIDRs

---

### Free / Expansion Space

| Range             | Purpose                         |
| ----------------- | ------------------------------- |
| `10.58.0.40–59`   | Free / future allocation buffer |
| `10.58.0.80–99`   | Free                            |
| `10.58.0.222–239` | Free / reserved for future use  |

---

### Dynamic & Edge Devices

| Range             | Purpose                             |
| ----------------- | ----------------------------------- |
| `10.58.0.100–199` | DHCP clients                        |
| `10.58.0.200–209` | IoT physical devices                |
| `10.58.0.240–241` | Legacy IoT servers (to be migrated) |

---

### Multus / Macvlan Networking

| Range             | Purpose                             |
| ----------------- | ----------------------------------- |
| `10.58.0.210–219` | Multus macvlan static IP allocation |

Notes:

* Used by workloads requiring L2 presence (e.g. Home Assistant discovery)
* Allocated via Multus IPAM
* Should not overlap with DHCP or MetalLB pools

---

## Design Principles

* **Intent over convenience**: ranges describe purpose, not just availability
* **No overlap** between:

  * DHCP
  * MetalLB
  * Multus
  * Node IPs
* **Production and test isolation** at the IP layer
* Address ranges should remain stable; services move, IP intent should not

---

## Operational Rules

* New services must select IPs from the correct intent range
* MetalLB pools must be explicitly defined and reviewed before change
* Multus ranges must be excluded from DHCP
* Test clusters must not reuse production IPs or VIPs

---

## Change Management

Any modification to this document should:

1. Be intentional
2. Be reviewed alongside firewall and DHCP configuration
3. Be applied **before** services are deployed

---

*Last updated: pre-Cilium / MetalLB migration*

