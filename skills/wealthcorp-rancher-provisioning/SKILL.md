---
name: wealthcorp-rancher-provisioning
description: This skill should be used when the user asks to operate or troubleshoot the WEALTHCORP Rancher-on-Proxmox node provisioning environment — "provision / scale an RKE2 cluster on Proxmox / pve01 from Rancher", "the pvenode node driver", "the wealth-cluster / wealthcorp Rancher (rkek8s.wealthcorp.la)", "reach pve01 / k8s01-03 / 10.10.110.x / 10.10.8.200", "why is node provisioning flaky / looping create-delete / churning", "nodes NotReady / Calico crash / etcd slow / controllers crash-looping on the wealth cluster", "cacerts / cert error on new nodes", or any WealthCorp Proxmox↔Rancher provisioning operation. Covers access (VPN + kubeconfig + ssh aliases), the topology (pve01, the single-host Rancher mgmt cluster, template 9000, the pvenode driver), and — most importantly — the ETCD-DISK reliability root cause that makes provisioning intermittently fail, plus the operational gotchas (never delete the last etcd node, cpu=host template, cacerts fix, credential attach).
version: 0.1.0
---

# WealthCorp Rancher-on-Proxmox Node Provisioning

> Provisioning RKE2/K3s clusters on a Proxmox host (`pve01`) from Rancher, via the custom **`pvenode`** node driver. **Reads are fine; writes to the Rancher mgmt cluster and to pve01 are user-gated.** The single most important thing in this skill is the **etcd-disk reliability root cause** below — if provisioning is "sometimes working, sometimes create/delete looping," it is almost always that, NOT the driver.

## Access
- **Proxmox host `pve01` = `10.10.8.200`** (PVE 8.4, standalone, 32 CPU / 188 GiB). Reachable **only over the UniFi Identity VPN** — profile **"One-Click VPN"**: `scutil --nc start "C61AE06A-E04F-4E6D-8185-745B0329004C"`. SSH: **`ssh pve`** (root, key `~/.ssh/ssh-keys/pve01/id_ed25519`).
- **Rancher mgmt cluster (`wealth-cluster`, the `local` cluster):** `export KUBECONFIG=~/.kube/wealth-cluster.config` — API `https://10.10.110.10:6443`. Rancher server-url **`https://rkek8s.wealthcorp.la`** → `10.10.110.103` (the `rancher` LoadBalancer, direct to pods).
- **Mgmt cluster nodes** = pve01 VMs: **k8s01/k8s02/k8s03 = VMIDs 2100/2101/2102** (10.10.110.10/.11/.12), plus VMID 2103 `k8s01-control-plane`. SSH: **`ssh wealth-k8s01 | wealth-k8s02 | wealth-k8s03`** (user `wealth`, same pve01 key).
- **Node network:** `vmbr2 / VLAN 110 = 10.10.110.0/24 (DHCP)`.

## Topology
| Thing | Value |
|---|---|
| Proxmox host | `pve01` = `10.10.8.200`, standalone, storage `local-lvm` (lvmthin, ~6.5 TB free) |
| Rancher mgmt cluster | `wealth-cluster` = 3 VMs (k8s01-03) on pve01, RKE ` v1.31.10`, API `10.10.110.10:6443` |
| Node driver | **`pvenode`** — repo `14f3v/pve-rancher-node-driver` (public), released **v0.1.0** |
| Node template | **VMID 9000** `ubuntu-2404-pvenode` — cloud-init + qemu-guest-agent, **`cpu: host`**, net0 on vmbr2/VLAN110 |
| PVE role/user | `RancherPVENode` role + `rancher@pve` user + cloud credential `cc-j29zz` (ns `cattle-global-data`) |

## The `pvenode` node driver
A native Rancher node driver (docker-machine/rancher-machine plugin) that clones a Proxmox template, detects the DHCP IP via MAC-matched qemu-guest-agent, and hands off to RKE2 provisioning. Machine-config fields (free text in the UI): `template=9000`, `storage=local-lvm`, `bridge=vmbr2`, `vlan=110`, `cpuType=host`, `insecureTls=on`, `sshUser=rancher`, uncheck Linked Clone OR clear Storage (the driver rejects linked+storage). Download URL is a GitHub release asset; NodeDriver resource **must** be named `pvenode` (the machineprovision handler looks it up by driver name).

---

## ⭐ RELIABILITY ROOT CAUSE — slow etcd disk on the mgmt cluster
**Symptom:** node provisioning is unreliable — "sometimes provisions fine, sometimes not, sometimes loops create/delete." **This is the Rancher management cluster's platform health, NOT the pvenode driver.** Every `qmclone`/`qmstart`/guest-agent-IP the driver does succeeds; the churn is Rancher *rolling* machines that never finish registering.

### The chain (all evidence-backed, diagnosed 2026-07)
1. **etcd is a SINGLE member (only k8s01)** despite all 3 nodes labeled `control-plane,etcd,worker` (`etcdctl member list` → 1). No HA; all etcd load on one node.
2. **etcd data is on slow HDD.** k8s01 `scsi0 = local-lvm:vm-2100-disk-0` → local-lvm → PV `/dev/sda3` → **sda = Broadcom MegaRAID `5350-8i` logical volume, ROTA=1 (rotational), `/sys/block/sda/queue/write_cache = write through`.** pve01 has **NO SSD/NVMe** — sda (7.6T RAID), sdb (1.8T WD Purple = `backup2`), sdc (3.6T WD = `backup`, 99% full); Ceph `k8s-pool` disabled.
3. **etcd fsync is far too slow** (etcd metrics at `http://127.0.0.1:2381/metrics` on k8s01): `wal_fsync` avg **~19 ms**, `backend_commit` avg **~34 ms**. etcd needs p99 `wal_fsync` <10ms / `backend_commit` <25ms. `raftTerm≈133` ≈ the ~131 etcd restarts. Idle health is fast (~10ms); the problem is fsync **spikes under write load**.
4. **Consequence:** apiserver writes (lease renewals, `timeout=5s`) intermittently exceed 5s → every controller loses its lease and crash-loops: `kube-controller-manager` (~749 restarts), `kube-scheduler` (~707), `kube-apiserver` (~188), Rancher's `capi-controller-manager` (~267) — all logging `leaderelection lost` / `context deadline exceeded` to `10.10.110.10:6443`. While they're down, machine reconcile stalls → new nodes never report `status.ready`/register → planner `waiting for viable init node` → rolls them → **create/delete churn**. A node succeeds only when it catches a healthy window.
5. **Vicious cycle:** the driver clones into the SAME local-lvm/sda spindle etcd uses, so provisioning I/O starves etcd fsync → churn worsens. Concurrent clones also hit PVE storage-lock timeouts (`can't lock file '/var/lock/pve-manager/pve-storage-local-lvm' - got timeout`); the driver retries.

### Fix priority (mostly infra, out of the driver's hands)
1. **RAID write-back cache (biggest no-new-hardware win):** sda is `write through`. If the MegaRAID 5350-8i has a healthy BBU/CacheVault, set the VD cache policy to **WriteBack** → etcd fsync ~19ms→~1ms. Check with `storcli64 /c0/vall show all` + `/c0/bbu show all` (storcli NOT installed on pve01 — install it or use the RAID BIOS). If no/failed BBU, write-through is a safety default — don't override; add a BBU or an SSD.
2. **Put etcd on SSD/NVMe** (add a disk to pve01; move k8s01-03 or at least the etcd data dir there).
3. **Restore etcd HA to 3 members** — but only AFTER the disk is fast (3 slow members won't help).
4. **Cut clone I/O contention** — driver-side clone-retry hardening + don't clone onto etcd's spindle.

### Quick triage commands
```bash
export KUBECONFIG=~/.kube/wealth-cluster.config
kubectl get pods -n kube-system | grep -E 'etcd|apiserver|controller-manager|scheduler'   # look for CrashLoopBackOff + high restarts
kubectl get pods -n cattle-provisioning-capi-system                                        # capi-controller-manager restarts
# etcd fsync (on the node):
ssh wealth-k8s01 'curl -s http://127.0.0.1:2381/metrics | grep -E "wal_fsync_duration_seconds_(sum|count)|backend_commit_duration_seconds_(sum|count)"'
# etcd membership / health:
E=/etc/kubernetes/pki/etcd; kubectl exec -n kube-system etcd-k8s01 -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$E/ca.crt --cert=$E/server.crt --key=$E/server.key member list -w table
```

---

## Operational gotchas (order matters when standing a cluster up)
1. **NEVER delete the last etcd node.** Deleting the sole etcd member of a single-node master pool destroys quorum unrecoverably (if no snapshot) → planner `cluster was not sane … waiting for all etcd machines to be deleted` infinite loop. Use ≥3 etcd nodes, never delete the last one, and enable etcd snapshots. To clear the loop: delete + recreate the cluster.
2. **Template CPU must be `cpu: host`** (or ≥ `x86-64-v2`). Default `kvm64` is x86-64-v1 and modern Calico/glibc images crash-loop with `Fatal glibc error: CPU does not support x86-64-v2` → node stays NotReady → never registers. `qm set 9000 --cpu host`; also set `cpuType=host` in the machine config.
3. **cacerts CA drift** (strict agent-tls): if new nodes fail with `Please check … /cacerts`, the `cacerts` setting disagrees with the served cert. Fix = patch the `cacerts` management setting to the `tls-rancher-internal-ca` PEM (the CA the `/cacerts` endpoint actually serves); this flips `customized=true` and holds (a plain Rancher restart does NOT reconcile it).
4. **NodeDriver name must be `pvenode`** (not the UI auto-name `nd-xxxx`) or no provision job is created. Create via YAML with `metadata.name: pvenode`.
5. **Credential list empty in the UI** → the NodeDriver has no credential-field annotations; add `publicCredentialFields/privateCredentialFields/optionalCredentialFields/passwordFields` (field names = flags minus `pvenode-`, camelCased).
6. **Cloud credential doesn't attach via the UI** → patch `clusters.provisioning.cattle.io <cluster> -n fleet-default` `spec.cloudCredentialSecretName=cattle-global-data:cc-j29zz` directly.

## Bottom line
The `pvenode` driver works (built, released v0.1.0, validated E2E). Reliable provisioning is gated on the **wealth-cluster's slow-HDD / write-through etcd**. Until that's fixed (RAID write-back cache or SSD), NO node driver would provision reliably on this Rancher — so start any "provisioning is broken" investigation at the mgmt cluster's control-plane health, not the driver.
