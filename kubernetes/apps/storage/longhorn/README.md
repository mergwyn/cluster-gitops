# Longhorn Storage

Longhorn provides replicated block storage across three nodes. It replaces OpenEBS ZFS local PVs
for workload storage, eliminating node pinning and enabling pod rescheduling.

## Node Configuration

Disk configuration is managed via node annotations. Longhorn only schedules onto nodes explicitly
labelled and annotated — auto-discovery is disabled (`createDefaultDiskLabeledNodes: true`).

**Note:** ZFS datasets are not suitable as Longhorn disk paths — Longhorn uses sparse files for
replica data which ZFS does not support (`fallocate` operation not supported). All Longhorn disks
must be ext4-formatted block devices or partitions.

|Node   |Disk Path              |Backing Storage                                      |Capacity|Reserved|
|-------|-----------------------|-----------------------------------------------------|--------|--------|
|charlie|`/var/lib/longhorn-sda`|Seagate FireCuda 500 GB (`/dev/sda`, ext4)           |~457 GB |10 GB   |
|delta  |`/var/lib/longhorn-sda`|190 GB partition on Crucial MX500 (`/dev/sda4`, ext4)|~180 GB |10 GB   |
|hotel  |`/var/lib/longhorn-sda`|SanDisk SSD Plus 480 GB (`/dev/sda`, ext4)           |~436 GB |10 GB   |

**golf** is control-plane only and does not participate in Longhorn storage.

**delta** disk scheduling is currently disabled pending partition creation. Re-enable once
`/dev/sda4` is formatted and mounted — requires draining delta first as the disk is in active use.

## Node Labels and Annotations

Applied manually before initial deployment — not managed by Longhorn chart:

```bash
kubectl label node <node> node.longhorn.io/create-default-disk=config
kubectl annotate node <node> node.longhorn.io/default-disks-config='[...]'
```

See below for per-node annotation values.

### charlie

```json
[{"path":"/var/lib/longhorn-sda","allowScheduling":true,"storageReserved":10737418240,"tags":["ssd"]}]
```

`/var/lib/longhorn-sda` is mounted from `/dev/sda` (Seagate FireCuda). Added to `/etc/fstab`
by Puppet using the disk UUID.

### delta

```json
[{"path":"/var/lib/longhorn-sda","allowScheduling":false,"storageReserved":10737418240,"tags":["ssd"]}]
```

Pending: create partition `/dev/sda4` in the 204 GB free space between swap and rpool on
`/dev/sda` (Crucial MX500). Format ext4, mount at `/var/lib/longhorn-sda`, add to fstab.
Set `allowScheduling: true` once complete.

```
/dev/sda layout:
  sda1  512M   EFI
  sda2  48G    swap
        204G   FREE — target for Longhorn partition
  sda3  1.6T   ZFS rpool
```

### hotel

```json
[{"path":"/var/lib/longhorn-sda","allowScheduling":true,"storageReserved":10737418240,"tags":["ssd"]}]
```

`/var/lib/longhorn-sda` is mounted from `/dev/sda` (SanDisk SSD Plus). Added to `/etc/fstab`
during initial setup.

## Puppet Dependencies

The following must be managed by Puppet to survive node reprovisioning:

1. `open-iscsi` installed and `iscsid` enabled/started on all k3s nodes
1. `/etc/fstab` UUID-based mount entry for `/dev/sda` → `/var/lib/longhorn-sda` on charlie
1. `/etc/fstab` UUID-based mount entry for `/dev/sda` → `/var/lib/longhorn-sda` on hotel
1. `/etc/fstab` UUID-based mount entry for `/dev/sda4` → `/var/lib/longhorn-sda` on delta (pending)

## StorageClass

Longhorn is **not** set as the default StorageClass during migration. Workloads must explicitly
reference `storageClassName: longhorn`. Once migration is complete, this can be promoted to
default by setting `persistence.defaultClass: true` in `values.yaml`.

## Replicas

All volumes use 3 replicas by default, one per storage node. Replica soft anti-affinity is
enabled, allowing scheduling to proceed if a node is temporarily unavailable. With delta
currently disabled, volumes will schedule 2 replicas on charlie and 1 on hotel until delta
is re-enabled.

## Velero Integration

Longhorn CSI snapshots are enabled via a `VolumeSnapshotClass` defined in `extraObjects` in
`values.yaml`. Key requirements:

- `parameters.type: snap` must be set — without this Longhorn requires a backup target
  to be configured and will abort snapshot requests
- Label `velero.io/csi-volumesnapshot-class: "true"` must be present
- `snapshot.storage.kubernetes.io/is-default-class: "false"` to avoid overriding the
  OpenEBS snapshot class during migration

Velero backup and restore to a different namespace has been validated against a test workload.

## Workload Migration

Migration from OpenEBS ZFS local PVs to Longhorn is in progress. Recommended order:

1. Non-critical media/vpn workloads first (tautulli, overseerr, dispatcharr)
1. Monitoring (grafana, prometheus)
1. VPN namespace (sonarr, radarr, sabnzbd, qbittorrent, prowlarr)
1. Home-assistant namespace last (esphome, zigbee2mqtt, predbat, mosquitto, HA config)

Once all workloads are migrated, set `persistence.defaultClass: true` and remove OpenEBS.
