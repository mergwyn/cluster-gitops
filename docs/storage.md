# Storage Architecture

## Overview

The cluster uses two storage systems in parallel during migration, with Longhorn as the target
platform. OpenEBS ZFS local PVs are retained only for workloads not yet migrated.

All persistent storage is backed up via Velero with CSI snapshots, with data movement to both
MinIO (local) and IDrive E2 (offsite) backup targets.

---

## Storage Systems

### Longhorn (primary — all workloads)

Longhorn provides replicated block storage across three nodes, eliminating the node-pinning
constraint of OpenEBS ZFS local PVs and enabling pods to reschedule freely during node
maintenance.

**StorageClass:** `longhorn`
**Default:** not yet (set `persistence.defaultClass: true` in values once OpenEBS is removed)
**Replicas:** 3 (one per storage node)
**Data locality:** `best-effort` — Longhorn prefers routing I/O to the local replica

#### Storage Nodes

| Node    | Disk                                          | Mount Point             | Capacity  | Reserved |
|---------|-----------------------------------------------|-------------------------|-----------|----------|
| charlie | Seagate FireCuda 500 GB (`/dev/sda`, ext4)    | `/var/lib/longhorn-sda` | ~457 GB   | 10 GB    |
| delta   | Crucial MX500 partition (`/dev/sda4`, ext4)   | `/var/lib/longhorn-sda` | ~180 GB   | 10 GB    |
| hotel   | SanDisk SSD Plus 480 GB (`/dev/sda`, ext4)    | `/var/lib/longhorn-sda` | ~436 GB   | 10 GB    |

**golf** is control-plane only and does not participate in Longhorn storage.

#### Key Design Decisions

- **ZFS datasets cannot be used as Longhorn disk paths** — Longhorn uses sparse files for replica
  data which ZFS does not support (`fallocate` not supported). All Longhorn disks are ext4-formatted
  block devices or partitions.
- **Dedicated disks/partitions** are used rather than directories on the root filesystem, giving
  Longhorn full control over disk space and avoiding interference with ZFS rpools.
- **`replicaSoftAntiAffinity: true`** allows volumes to schedule even if a node is temporarily
  unavailable, at the cost of temporarily reduced redundancy.
- **Auto-discovery is disabled** (`createDefaultDiskLabeledNodes: true`) — disks are configured
  explicitly via node annotations to prevent Longhorn claiming unexpected storage.

#### Node Annotations

Disk configuration is applied via node labels and annotations, not managed by the Longhorn chart:

```bash
kubectl label node <node> node.longhorn.io/create-default-disk=config
kubectl annotate node <node> node.longhorn.io/default-disks-config='[...]'
```

Per-node annotation values:

**charlie:**
```json
[{"path":"/var/lib/longhorn-sda","allowScheduling":true,"storageReserved":10737418240,"tags":["ssd"]}]
```

**delta:**
```json
[{"path":"/var/lib/longhorn-sda","allowScheduling":true,"storageReserved":10737418240,"tags":["ssd"]}]
```

**hotel:**
```json
[{"path":"/var/lib/longhorn-sda","allowScheduling":true,"storageReserved":10737418240,"tags":["ssd"]}]
```

---

### OpenEBS ZFS Local PV (legacy — pending removal)

OpenEBS ZFS local PVs were the original storage system. All workload PVCs have been migrated
to Longhorn. OpenEBS remains installed until confirmed safe to remove.

**StorageClass:** `openebs-zfspv`
**ZFS pool:** `rpool/zfspv` on each node
**VolumeSnapshotClass:** `openebs-zfspv-snapshot`

OpenEBS can be removed once:
1. All PVCs on `openebs-zfspv` are confirmed migrated
2. No Released PVs remain on `openebs-zfspv`
3. Longhorn is set as default StorageClass

---

### NFS (media and shared data)

Three NFS PVs provide access to shared media and backup storage hosted on delta:

| PV                        | NFS Export         | Namespace      | Purpose              |
|---------------------------|--------------------|----------------|----------------------|
| `nfs-media-pv`            | `10.58.0.14:/srv/media` | media     | Shared media library |
| `nfs-vpn-pv`              | `10.58.0.14:/srv/media` | vpn       | VPN-routed media access |
| `nfs-home-assistant-backup-pv` | delta NFS    | home-assistant | HA backup storage    |

NFS PVs have no node affinity and do not require migration.

---

## Backup Strategy

### Velero

Velero provides namespace-level backup and restore with CSI snapshot integration.

**Backup locations:**

| Name    | Provider | Bucket  | Default | Purpose         |
|---------|----------|---------|---------|-----------------|
| `minio` | aws (S3) | velero  | yes     | Local backup    |
| `idrive` | aws (S3) | velero | no      | Offsite backup  |

**CSI VolumeSnapshotClasses:**

| Name                    | Driver                | Used by  |
|-------------------------|-----------------------|----------|
| `longhorn-snapshot`     | `driver.longhorn.io`  | Velero CSI snapshots for Longhorn volumes |
| `openebs-zfspv-snapshot` | `zfs.csi.openebs.io` | Velero CSI snapshots for OpenEBS volumes |

**Critical configuration:** `parameters.type: snap` must be set on the Longhorn
VolumeSnapshotClass — without this, Longhorn requires a configured backup target and will
abort snapshot requests with `backup target default is not available`.

**Data movement:** `Snapshot Move Data: true` — snapshot data is moved to the backup location
rather than kept as a CSI snapshot reference only.

### Workload Migration Tool

`ops/migrate-workload` handles PVC migration between storage classes (or nodes) via
Velero backup/restore. Key features:

- ArgoCD deny sync window during migration to prevent reconciliation interference
- Prometheus operator scale-down detection for operator-managed StatefulSets
- Velero StorageClass mapping ConfigMap for automatic PVC remapping on restore
- Cleanup trap to restore state on failure

Usage for storage class migration:
```bash
./migrate-workload \
  --to-storage-class longhorn \
  --from-storage-class openebs-zfspv \
  --namespace <ns> \
  --app <app-name> \
  --argocd-app <argocd-app-name>
```

---

## Puppet Dependencies

The following node configuration is managed by Puppet:

1. `open-iscsi` installed and `iscsid` enabled/started on all k3s nodes (required by Longhorn)
2. `/etc/fstab` UUID-based mount for `/dev/sda` → `/var/lib/longhorn-sda` on charlie
3. `/etc/fstab` UUID-based mount for `/dev/sda` → `/var/lib/longhorn-sda` on hotel
4. `/etc/fstab` UUID-based mount for `/dev/sda4` → `/var/lib/longhorn-sda` on delta

---

## Observability

- **Prometheus ServiceMonitor** enabled for Longhorn (`metrics.serviceMonitor.enabled: true`)
- **Grafana dashboards** — to be added post-migration via ConfigMap with `grafana_dashboard: "1"`
  label (watched across all namespaces by Grafana sidecar)

---

## Pending Work

- [ ] Remove OpenEBS once all PVCs confirmed migrated
- [ ] Set Longhorn as default StorageClass (`persistence.defaultClass: true`)
- [ ] Add Longhorn Grafana dashboard ConfigMap
- [ ] Complete Puppet management of fstab and open-iscsi entries
- [ ] Delta `/dev/sda4` partition already created; ensure Puppet manages fstab entry
