# Chapter 1: Deconstructing the Control Plane & Cluster Bootstrap

> *"The control plane is not the cluster. It is the consensus mechanism that allows the cluster to exist."*

---

## 1. Title & Deep Dive

### 1.1 The Kubernetes Control Plane as a Distributed System

The Kubernetes control plane is a distributed system built on a single, strict contract: **every mutation to cluster state flows through the API server, is persisted in etcd, and is eventually reconciled by controllers.** There is no backdoor. There is no secondary write path. This contract is the architectural invariant that makes Kubernetes work at scale.

A production control plane consists of five components, but they are not equal participants:

| Component | Role | Failure Impact |
|-----------|------|----------------|
| **etcd** | Distributed key-value store; the only durable state | Total cluster amnesia if quorum is lost |
| **kube-apiserver** | REST gateway, admission control, authentication, authorization | All cluster operations halt; workloads continue running but cannot be modified |
| **kube-scheduler** | Assigns pending pods to nodes | New pods remain `Pending`; running pods unaffected |
| **kube-controller-manager** | Runs reconciliation loops (ReplicaSet, Deployment, Node, etc.) | Drift accumulates; no self-healing; orphaned resources |
| **cloud-controller-manager** | Cloud-specific reconciliation (LoadBalancer, Node routes) | Cloud integrations break; LoadBalancer IPs not provisioned |

Understanding the **failure hierarchy** is essential: etcd failure is catastrophic, API server failure is operational paralysis, and scheduler/controller failures are degraded self-healing. A senior engineer must know which failures are survivable and which require immediate intervention.

### 1.2 etcd: The Brain

#### 1.2.1 What etcd Actually Stores

etcd is a distributed, strongly consistent key-value store. In Kubernetes, every resource — every Pod, Deployment, ConfigMap, Secret, CRD instance — is serialized (typically as Protocol Buffers, not JSON despite what `kubectl get -o json` shows) and written to an etcd key under a hierarchical namespace:

```
/registry/pods/default/nginx-deployment-abc123
/registry/deployments/kube-system/coredns
/registry/secrets/cert-manager/cert-manager-webhook-tls
/registry/apiextensions.k8s.io/customresourcedefinitions/gateways.gateway.networking.k8s.io
```

The API server is the **only** component that reads from or writes to etcd. No controller, no kubelet, no scheduler touches etcd directly. This is a deliberate design choice: the API server acts as a serialization point that enforces admission control, validation, RBAC, and optimistic concurrency (via `resourceVersion`).

#### 1.2.2 The Raft Consensus Protocol

etcd achieves consistency through the [Raft consensus algorithm](https://raft.github.io/). Raft's key properties:

1. **Leader Election:** One node is the leader. All writes are proposed to the leader first. If the leader fails, remaining nodes hold an election. A new leader must receive votes from a majority (quorum).

2. **Log Replication:** The leader appends entries to its log and replicates them to followers. A write is committed only when a majority of nodes have persisted the entry. This means a 3-node cluster tolerates 1 failure; a 5-node cluster tolerates 2.

3. **Term-Based Fencing:** Each election increments a monotonic term counter. Stale leaders from previous terms cannot commit writes — followers reject proposals with outdated terms.

4. **Linearizable Reads:** By default, etcd serves reads through the leader to ensure they reflect the latest committed state. This adds latency. You can opt into `serializable` reads for stale-but-fast queries (useful for monitoring, never for controllers).

**Quorum math is non-negotiable:**

| Cluster Size | Quorum | Tolerable Failures | Notes |
|:---:|:---:|:---:|---|
| 1 | 1 | 0 | Development only |
| 2 | 2 | 0 | **Worse than 1 — harder to reach quorum** |
| 3 | 2 | 1 | Production minimum |
| 5 | 3 | 2 | Large production; adds write latency |
| 7 | 4 | 3 | Rarely justified; diminishing returns |

**Why 2-node etcd is worse than 1-node:** With 2 nodes, quorum requires both nodes. Losing either node means no writes. You've doubled the hardware without gaining any fault tolerance — you've actually made things worse because you now have two machines that can independently cause a total outage.

#### 1.2.3 etcd Storage Internals: bbolt, B+ Trees, and MVCC

Under the hood, etcd persists data using **bbolt** (a maintained fork of BoltDB), an embedded key-value store written in Go.

**B+ Tree on Disk:**
- bbolt organizes data in a B+ tree of 4 KB pages
- Leaf pages hold key-value pairs; internal pages hold routing keys
- Pages are **never modified in-place** — bbolt uses copy-on-write semantics
- Modified pages are written to free pages reclaimed from a freelist, and old pages are released once no open transaction references them
- The database is a single file (`member/snap/db` in etcd's data directory)

**MVCC (Multi-Version Concurrency Control):**
- Every etcd write creates a new **revision** rather than overwriting the previous value
- Revisions are monotonically increasing 64-bit integers
- This enables **watch streams** — a client can say "tell me everything that changed since revision N"
- Kubernetes controllers use this mechanism via the **watch cache** in the API server
- Historical revisions accumulate until **compaction** removes them
- If you forget to compact, the database grows unbounded. etcd auto-compaction should always be configured (RKE2 sets this by default)

**Write-Ahead Log (WAL):**
- Before committing to bbolt, etcd appends every Raft entry to a WAL on disk
- The WAL ensures that committed entries survive crashes even if the bbolt transaction hadn't flushed
- WAL files live in `member/wal/` and are segmented at 64 MB boundaries
- **This is why etcd demands low-latency SSDs:** every write requires an `fsync` to the WAL before the commit can be acknowledged to the leader

**Snapshots:**
- Periodically, etcd takes a consistent snapshot of the entire bbolt database
- Snapshots are used for: (a) truncating the WAL so it doesn't grow forever, (b) bootstrapping new cluster members, (c) disaster recovery
- RKE2 manages automatic etcd snapshots and stores them locally plus optionally to S3-compatible targets

#### 1.2.4 etcd Performance Tuning and Failure Modes

**Critical performance factors:**

| Factor | Impact | Recommendation |
|--------|--------|----------------|
| Disk I/O latency | Directly affects commit latency; high latency = slow writes, leader instability | NVMe or fast SSD; never share with noisy workloads |
| Network RTT between members | Affects Raft heartbeat and replication latency | Keep members in the same data center; <2ms RTT ideal |
| `--heartbeat-interval` | How often the leader sends heartbeats (default: 100ms) | Increase to 200-500ms on high-latency networks |
| `--election-timeout` | How long followers wait before starting election (default: 1000ms) | Must be ≥5× heartbeat interval |
| `--quota-backend-bytes` | Maximum database size (default: 2 GB in etcd, 8 GB in RKE2) | Monitor usage; alarm triggers at quota |
| `--auto-compaction-retention` | How long to retain old revisions | RKE2 defaults to 5 minutes; tune based on watch patterns |
| `--snapshot-count` | Raft entries between snapshots (default: 10000) | Lower = more frequent snapshots = faster WAL truncation |

**Common failure modes:**

1. **Split brain (impossible in Raft):** Raft's quorum requirement mathematically prevents split brain. There can only be one leader per term. This is not a theoretical guarantee — it's a proven property of the algorithm.

2. **Quorum loss:** If you lose majority, the cluster becomes read-only. Writes are rejected. Kubernetes control loops halt. Existing workloads continue running but are unmanaged. Recovery requires either restoring a failed member or performing an unsafe forced new-cluster bootstrap.

3. **Disk pressure / slow disk:** etcd applies backpressure when disk latency exceeds thresholds. The leader may miss heartbeat windows and lose leadership. Rapid leader elections ("election storms") ensue. The cluster appears to work intermittently. **This is the #1 etcd production issue.** Monitor `etcd_disk_wal_fsync_duration_seconds` and `etcd_disk_backend_commit_duration_seconds`.

4. **Database size alarm:** When the database exceeds `--quota-backend-bytes`, etcd triggers an alarm and refuses all writes. The cluster enters a degraded state. You must defragment and disarm the alarm. In Kubernetes, this manifests as API server write failures across all namespaces.

5. **Watch starvation:** If too many controllers open expensive watches (especially on CRDs with large objects), the API server's watch cache can fall behind etcd. Controllers see stale state and make incorrect reconciliation decisions.

### 1.3 kube-apiserver: The Gateway

The API server is far more than a REST endpoint. It is a **serialization point** — every cluster mutation flows through its processing pipeline:

```
Client Request
  → Authentication (x509, OIDC, ServiceAccount tokens, webhook)
  → Authorization (RBAC, webhook, ABAC — deprecated)
  → Admission Control
      → Mutating Admission Webhooks (can modify the object)
      → Object Schema Validation
      → Validating Admission Webhooks (can reject the object)
      → ValidatingAdmissionPolicy (CEL-based, in-process — no webhook round-trip)
  → etcd Write (with optimistic concurrency via resourceVersion)
  → Response to Client
```

**Key architectural properties:**

1. **Stateless and horizontally scalable:** The API server holds no persistent state. You can run 3, 5, or 10 instances behind a load balancer. All state lives in etcd.

2. **Watch cache:** The API server maintains an in-memory cache of recent object revisions. When a controller issues a `WATCH`, it reads from this cache rather than hitting etcd directly. This is critical for performance — without it, etcd would be crushed by watch traffic from hundreds of controllers.

3. **Optimistic concurrency:** Every Kubernetes object carries a `resourceVersion` (derived from the etcd revision). When you update an object, the API server checks that your `resourceVersion` matches the current one in etcd. If it doesn't (because someone else modified the object), your write is rejected with a `409 Conflict`. Controllers handle this with retry loops.

4. **Aggregation layer:** Custom API servers (like metrics-server) register with the aggregation layer, making their APIs appear as native Kubernetes APIs under `/apis/metrics.k8s.io/`.

5. **API priority and fairness (APF):** Since Kubernetes 1.29+, the API server uses flow control to prevent any single client from starving others. Requests are classified into priority levels and queued with fair scheduling. This prevents, for example, a misbehaving CRD controller from blocking `kubectl` commands.

### 1.4 kube-scheduler: The Placement Engine

The scheduler watches for pods with `spec.nodeName` unset (i.e., `Pending`), scores candidate nodes through a plugin-based framework, and binds the pod to the highest-scoring node.

**Scheduling plugins run in two phases:**

1. **Filter phase:** Eliminate nodes that cannot run the pod (insufficient resources, taints, affinity violations, topology constraints)
2. **Score phase:** Rank remaining nodes by desirability (balanced resource utilization, data locality, zone spreading)

The scheduler is a single active instance with leader election (same pattern as controller-manager). In RKE2, it runs as a static pod.

### 1.5 kube-controller-manager: The Reconciliation Engine

The controller-manager embeds ~40 controllers that implement Kubernetes' self-healing behavior. Each controller runs a **reconciliation loop:**

```
Watch for state changes (via API server watch cache)
  → Compare desired state (spec) vs actual state (status)
  → Take corrective action (create/delete/update sub-resources)
  → Update status
  → Re-watch
```

Notable controllers include:

| Controller | Reconciles |
|------------|-----------|
| **ReplicaSet** | Ensures desired pod count matches actual running pods |
| **Deployment** | Manages ReplicaSet rollouts (rolling update, rollback) |
| **Node** | Monitors node heartbeats; evicts pods from unreachable nodes |
| **Endpoint / EndpointSlice** | Syncs Service selectors to backend pod IPs |
| **Job** | Manages pod completions for batch workloads |
| **Garbage Collector** | Cascading deletion of owner references |

**Leader election:** Only one controller-manager instance is active at a time. Others are on standby. Leadership is determined via a Lease object in etcd. If the active instance fails, another acquires the lease within the `--leader-elect-lease-duration` window (default: 15s).

### 1.6 RKE2: Anatomy of a Next-Generation Distribution

RKE2 (Rancher Kubernetes Engine 2) is a CNCF-conformant Kubernetes distribution from SUSE that combines the operational simplicity of K3s with production hardening:

**Key architectural decisions:**

1. **Static pods for the control plane:** RKE2 runs etcd, kube-apiserver, kube-scheduler, and kube-controller-manager as **static pods** managed by kubelet. The manifests are extracted from hardened container images and placed in `/var/lib/rancher/rke2/agent/pod-manifests/`. This is fundamentally different from kubeadm (which also uses static pods but with less opinionation) and K3s (which runs components as goroutines in a single process).

2. **Embedded etcd:** etcd is deployed automatically with no external cluster setup required. One etcd pod per server node. Quorum is maintained automatically across `server` nodes.

3. **Containerd only:** RKE2 embeds containerd as the sole runtime. No Docker, no CRI-O. The containerd binary and configuration are bundled with the RKE2 release.

4. **CIS hardening by default:** RKE2 ships with CIS Kubernetes Benchmark compliance out of the box. Pod security, audit logging, and etcd encryption are enabled or easily enabled without manual hardening guides.

5. **FIPS 140-2 support:** For government and regulated workloads, RKE2 provides FIPS-validated crypto builds.

6. **`cni: none` bootstrap strategy:** RKE2 can start with no CNI, allowing you to install your own (like Cilium) before any pod networking exists. This is critical for the architecture described in this book.

**RKE2 startup sequence on a server node:**

```
systemctl start rke2-server
  → RKE2 process starts
  → Pulls/extracts container images from bundled airgap tarball or registry
  → Writes static pod manifests for etcd
  → Starts kubelet
  → Kubelet starts etcd static pod
  → etcd forms or joins cluster
  → RKE2 writes static pod manifests for kube-apiserver, scheduler, controller-manager
  → Kubelet starts remaining control plane static pods
  → API server connects to etcd
  → kube-proxy or CNI starts (depending on config)
  → Node registers itself
  → Bootstrap complete
```

**RKE2 configuration hierarchy:**

```
/etc/rancher/rke2/config.yaml          # Primary configuration
/etc/rancher/rke2/config.yaml.d/*.yaml  # Drop-in overrides (merged alphabetically)
/var/lib/rancher/rke2/                  # Runtime state, data directory
/var/lib/rancher/rke2/server/token      # Cluster join token
/var/lib/rancher/rke2/agent/pod-manifests/  # Static pod manifests
/var/lib/rancher/rke2/server/db/        # etcd data (if embedded)
```

### 1.7 kube-vip: Stable API VIP in ARP Mode

In a bare-metal or on-premises deployment, there is no cloud load balancer to front the API server. Without a Virtual IP (VIP), your kubeconfig points to a single node's IP — making your "HA" cluster operationally single-point-of-failure.

**kube-vip** solves this by providing a floating VIP that moves between control-plane nodes via leader election.

**ARP mode mechanics:**

1. kube-vip runs as a static pod on each control-plane node (or as a DaemonSet)
2. Instances perform leader election via Kubernetes Lease objects (or Raft, depending on config)
3. The elected leader binds the VIP to its network interface and broadcasts a **Gratuitous ARP (GARP)** announcement
4. The GARP updates ARP tables on all devices in the L2 broadcast domain, mapping the VIP's MAC address to the leader's interface
5. If the leader node fails, a new leader is elected within seconds, binds the VIP, and sends a new GARP
6. Traffic failover is transparent to clients

**Why ARP mode at bootstrap time:**

- BGP mode requires an upstream router and a running BGP speaker (Cilium, in this architecture)
- At bootstrap time, there is no CNI (`cni: none`), so Cilium is not running
- ARP mode works with only L2 connectivity — no external dependencies
- This is precisely why the architecture in this book uses ARP mode for the API VIP and defers BGP to post-CNI phases

**Failure modes and limitations:**

| Scenario | Impact |
|----------|--------|
| Leader node crashes | New leader elected in 2-5 seconds; brief API unavailability |
| Network partition splitting L2 domain | Two nodes may claim the VIP (L2 split-brain) — rare on a single switch but possible with misconfigured VLANs |
| ARP cache staleness on clients | Most OSes refresh ARP within seconds of GARP; some older switches require manual ARP timeout tuning |
| All control-plane nodes down | VIP is unavailable; no failover possible |
| ARP mode traffic bottleneck | All API traffic flows through a single leader node; not an issue at 3-node scale but matters at 50+ nodes |

**API certificate SAN requirement:**

The API server's TLS certificate must include both the VIP (`10.20.10.10`) and the DNS name (`k8s-api.lab.home.arpa`) as Subject Alternative Names. RKE2 supports this via the `tls-san` configuration option:

```yaml
# /etc/rancher/rke2/config.yaml
tls-san:
  - "10.20.10.10"
  - "k8s-api.lab.home.arpa"
```

---

## 2. Competitive Landscape Analysis

### 2.1 Kubernetes Distributions

| Criterion | **RKE2** | **K3s** | **kubeadm** | **Talos Linux** |
|-----------|----------|---------|-------------|-----------------|
| **Primary use case** | Production on-prem, government, regulated | Edge, IoT, development, lightweight production | Learning, DIY production, maximum flexibility | Immutable infrastructure, zero-trust, GitOps-native |
| **Control plane model** | Static pods from hardened images | Single binary, goroutines | Static pods (manual setup) | API-managed, immutable OS |
| **etcd** | Embedded, automatic HA | Embedded (or external/SQLite) | External setup required | Embedded, automatic HA |
| **CIS hardened** | Yes, by default | No (manual hardening required) | No (manual hardening required) | Yes, by design (no shell, no SSH) |
| **FIPS 140-2** | Yes | No | No | No (but minimal attack surface) |
| **CNI** | Bundled Canal; supports `cni: none` for BYO | Bundled Flannel; supports `--flannel-backend=none` | None bundled; user must install | Bundled Flannel; supports BYO |
| **Container runtime** | Containerd (embedded) | Containerd (embedded) | Containerd, CRI-O (user choice) | Containerd (embedded) |
| **OS requirement** | Any supported Linux | Any supported Linux | Any supported Linux | **Is the OS** — Talos replaces your Linux distro |
| **SSH access** | Yes (standard Linux) | Yes (standard Linux) | Yes (standard Linux) | **No SSH** — API-only management |
| **Upgrade mechanism** | Binary replacement + rolling restart | Binary replacement | `kubeadm upgrade` workflow | Atomic OS image swap |
| **Airgap support** | Native (bundled tarballs) | Native (bundled images) | Manual image pre-pull | Native (machine config) |
| **Operational complexity** | Low-Medium | Low | High | Low (after learning curve) |
| **Learning value** | Medium (some abstraction) | Medium (high abstraction) | Very High (all manual) | Medium-High (different paradigm) |
| **Vendor** | SUSE/Rancher | SUSE/Rancher | Kubernetes SIG | Sidero Labs |

### 2.2 Pros/Cons Deep Dive

**RKE2:**
- ✅ CIS-hardened out of the box; FIPS builds available
- ✅ Embedded etcd with automatic HA — no external etcd cluster management
- ✅ `cni: none` makes BYO CNI (Cilium) clean
- ✅ Static pod model gives full kubelet lifecycle management of control plane
- ✅ Strong airgap story with bundled image tarballs
- ❌ SUSE/Rancher ecosystem dependency for support
- ❌ Less community documentation than kubeadm for edge cases
- ❌ Opinionated — harder to customize deeply than kubeadm

**K3s:**
- ✅ Smallest footprint; runs on Raspberry Pi and edge devices
- ✅ Single binary, trivial install
- ✅ SQLite option for single-node (no etcd overhead)
- ❌ Not CIS-hardened by default; requires manual work
- ❌ No FIPS builds
- ❌ Single-process architecture makes debugging harder (all components share one process)
- ❌ Goroutine-based components mean a scheduler bug can crash the entire control plane

**kubeadm:**
- ✅ Maximum transparency — you see and control everything
- ✅ Best for learning Kubernetes internals
- ✅ No vendor lock-in; upstream Kubernetes SIG project
- ✅ Full flexibility in component versions and configurations
- ❌ Significant operational overhead (certificate rotation, etcd management, upgrades)
- ❌ No built-in HA without external tooling (load balancer, etcd clustering)
- ❌ No CIS hardening without manual intervention
- ❌ Upgrade process is manual and error-prone at scale

**Talos Linux:**
- ✅ Immutable OS eliminates configuration drift entirely
- ✅ No SSH = minimal attack surface; API-only management
- ✅ Atomic upgrades — the entire OS image is swapped, not patched
- ✅ 12 binaries total; 47% less disk usage vs kubeadm
- ✅ Excellent for GitOps-driven infrastructure
- ❌ Steep learning curve — different paradigm than traditional Linux admin
- ❌ Cannot install arbitrary packages or debugging tools on nodes
- ❌ Troubleshooting requires Talos API tooling (`talosctl`)
- ❌ Smaller community than RKE2/K3s
- ❌ No FIPS certification

### 2.3 API VIP Solutions

| Criterion | **kube-vip (ARP)** | **kube-vip (BGP)** | **keepalived + HAProxy** | **Cloud LB (NLB/ILB)** |
|-----------|-------------------|-------------------|------------------------|----------------------|
| **Pre-CNI bootstrap** | ✅ Yes | ❌ Needs BGP peer | ✅ Yes (systemd) | ✅ Yes (external) |
| **L2 only** | ✅ | ❌ Needs L3 | ✅ | N/A |
| **Traffic distribution** | Single leader | All nodes advertise | Single leader (active-passive) | Distributed |
| **Operational complexity** | Low (single static pod) | Medium | Medium-High (two components) | Low (managed) |
| **Scalability** | Limited by single leader | Good (ECMP) | Limited by single leader | Excellent |
| **Bare-metal** | ✅ | ✅ | ✅ | ❌ |
| **Failure detection** | Lease-based (seconds) | BGP timers (configurable) | VRRP (sub-second) | Health checks (configurable) |

---

## 3. Under the Hood

### 3.1 Linux Kernel Primitives Behind the Control Plane

The Kubernetes control plane runs on Linux, and understanding the kernel primitives it depends on is essential for debugging production issues.

#### 3.1.1 Namespaces and cgroups (Container Isolation for Static Pods)

RKE2's static pods (etcd, API server, etc.) run as containers via containerd. Each container gets:

**Linux namespaces (isolation):**

| Namespace | What It Isolates | Control Plane Impact |
|-----------|-----------------|---------------------|
| `pid` | Process IDs | etcd's PID 1 inside the container is not PID 1 on the host |
| `net` | Network stack | Static pods use `hostNetwork: true` — they share the host's network namespace |
| `mnt` | Filesystem mounts | etcd sees only its mounted data directory, not the full host filesystem |
| `uts` | Hostname | Container hostname matches pod name |
| `ipc` | Inter-process communication | Isolated shared memory segments |
| `user` | User/group IDs | May remap UIDs depending on runtime config |

**Critical detail: `hostNetwork: true`**

All RKE2 control plane static pods run with `hostNetwork: true`. This means they bind directly to the host's IP addresses and ports. The API server listens on `0.0.0.0:6443` on the host, not inside a pod network. This is **required** because:
- The API server must be reachable before any CNI exists
- kube-vip needs to manage the host's network interface for ARP
- etcd peer communication uses host IPs

**cgroups v2 (resource accounting):**

Modern Linux distributions (including Ubuntu 24.04 LTS) use cgroups v2 as the unified hierarchy for resource management:

```
/sys/fs/cgroup/
  └── kubelet.slice/
      └── kubepods.slice/
          ├── kubepods-burstable.slice/
          │   └── kubepods-burstable-pod<uid>.slice/
          │       └── cri-containerd-<container-id>.scope/
          └── kubepods-besteffort.slice/
```

For static pods, kubelet creates cgroup scopes under the kubelet's own slice. Resource requests/limits on the etcd static pod directly translate to cgroup memory limits (`memory.max`) and CPU bandwidth (`cpu.max`).

**Why this matters:** If etcd's cgroup memory limit is hit, the OOM killer terminates the etcd process. This is a common cause of "etcd disappeared" in resource-constrained clusters. Monitor `container_memory_working_set_bytes` for the etcd container.

#### 3.1.2 The Network Stack: How kube-vip ARP Actually Works

When kube-vip adds a VIP to an interface, it uses the `netlink` API (the kernel interface for network configuration, replacing `ifconfig`/`route`):

```
1. Leader election completes
2. kube-vip calls netlink to add VIP as a secondary address:
   ip addr add 10.20.10.10/32 dev eth0
3. kube-vip sends a Gratuitous ARP:
   - ARP Request where sender IP = target IP = 10.20.10.10
   - Sender MAC = eth0's MAC address on the leader node
   - Broadcast to ff:ff:ff:ff:ff:ff
4. All hosts on the L2 segment update their ARP tables:
   10.20.10.10 → <leader's MAC>
5. Subsequent TCP connections to 10.20.10.10:6443 route to the leader
```

**Gratuitous ARP deep dive:**

A GARP is an ARP request where the sender and target protocol addresses are identical. It serves two purposes:
1. **ARP cache update:** Forces all devices on the broadcast domain to update their mapping for the VIP's IP
2. **Duplicate address detection:** If another device already holds this IP, it will respond, indicating a conflict

The GARP is sent as a broadcast Ethernet frame (`ff:ff:ff:ff:ff:ff`), so every host on the VLAN sees it. Switches update their MAC address tables, and hosts update their ARP caches. This is why kube-vip ARP mode requires L2 adjacency — the GARP must reach all potential clients.

#### 3.1.3 Filesystem I/O: Why etcd Needs Fast Disks

etcd's write path hits the disk twice per committed entry:

```
Raft proposal accepted
  → Append to WAL (Write-Ahead Log)
  → fsync() WAL segment  ← This is the latency-critical path
  → Apply to bbolt B+ tree in memory
  → Periodically commit bbolt transaction to disk
  → fsync() bbolt database file
```

The `fsync()` system call flushes the kernel's page cache to persistent storage. On a slow disk (spinning HDD, network-attached storage, or an SSD with a full write buffer), this call blocks for milliseconds. etcd's Raft heartbeat interval is 100ms by default — if a single `fsync` takes longer than a heartbeat interval, the leader may appear to have failed, triggering an unnecessary election.

**Diagnosing disk issues:**

```bash
# Check etcd WAL fsync latency (should be <10ms p99)
etcdctl --endpoints=https://127.0.0.1:2379 \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  endpoint status --write-out=table

# Check I/O scheduler (should be 'none' or 'mq-deadline' for NVMe)
cat /sys/block/nvme0n1/queue/scheduler

# Monitor WAL fsync with fio benchmark (simulates etcd write pattern)
fio --name=wal-test --ioengine=sync --rw=write --bs=2300 \
    --numjobs=1 --size=100M --fdatasync=1 --runtime=30
# p99 fdatasync should be <10ms
```

#### 3.1.4 Certificate Infrastructure

The Kubernetes control plane uses mutual TLS extensively. RKE2 auto-generates and manages the entire PKI:

```
Root CA
├── kube-apiserver serving cert (SANs: VIP, DNS names, node IPs)
├── kube-apiserver → etcd client cert
├── kube-apiserver → kubelet client cert
├── etcd peer certs (member-to-member)
├── etcd server cert (for API server connections)
├── kube-scheduler → API server client cert
├── kube-controller-manager → API server client cert
├── front-proxy CA (for API aggregation)
└── ServiceAccount signing key pair
```

RKE2 stores these under `/var/lib/rancher/rke2/server/tls/`. Certificates are auto-rotated before expiry. **If the clock drifts significantly between nodes, certificate validation fails and the cluster breaks.** Ensure NTP/chrony is configured on all nodes.

---

## 4. Cloud vs. On-Prem Context

### 4.1 How the Control Plane Differs Across Environments

| Aspect | **On-Prem (RKE2)** | **AWS EKS** | **GCP GKE** | **Azure AKS** |
|--------|-------------------|-------------|-------------|---------------|
| **etcd management** | You own it. Backups, monitoring, disk perf, quorum — all yours | Fully managed. You never see etcd. AWS runs it on their infra | Fully managed. Google runs it. You get no access | Fully managed by Azure |
| **API server endpoint** | kube-vip VIP + DNS. You manage HA | AWS-managed NLB endpoint. Multi-AZ by default. 99.95% SLA | Google-managed endpoint. Regional by default. 99.95% SLA | Azure-managed endpoint. 99.95% SLA with AZ |
| **Control plane scaling** | Fixed (3 or 5 nodes). You add capacity | Automatic. AWS scales API server based on load | Automatic. GKE auto-scales API server replicas | Automatic scaling |
| **etcd backup** | Manual (snapshot to S3-compatible target) or RKE2 auto-snapshot | AWS handles it. You can't take manual snapshots | Google handles it. Automatic | Azure handles it |
| **Certificate management** | RKE2 auto-generates and rotates. You can customize SANs | AWS manages. You use OIDC for authentication | Google manages. You use Workload Identity | Azure manages. Azure AD integration |
| **API server admission** | Full control over webhooks, policies | Full control, but some AWS-injected webhooks | Full control, but GKE adds its own mutating webhooks | Full control, but Azure adds policy webhooks |
| **Upgrade process** | Rolling RKE2 binary upgrade, one node at a time | In-place API update. AWS handles it. You upgrade node groups separately | GKE auto-upgrades (configurable). Surge upgrades available | AKS in-place upgrade. You control node pool upgrades |
| **Cost** | Hardware + electricity + your time | ~$0.10/hr per cluster (~$73/mo) for control plane | Free for Standard; $0.10/hr for Autopilot management fee | Free tier for AKS; paid SLA tier available |
| **Failure blast radius** | Limited to your hardware; you control isolation | Shared infrastructure (noisy neighbor possible on control plane) | Shared infrastructure | Shared infrastructure |

### 4.2 What You Gain On-Prem

1. **Full observability into etcd:** You can instrument, benchmark, and tune etcd directly. In managed services, etcd is a black box. When things go wrong, you have no metrics, no logs, and no ability to run `etcdctl endpoint status`.

2. **Complete certificate authority control:** You own the root CA. You can audit, rotate, or extend the PKI however you want. Managed services use their own CAs with limited customization.

3. **No API rate limiting surprises:** Managed Kubernetes services impose API request throttling that isn't always well-documented. On-prem, your API server capacity is limited only by your hardware.

4. **Network architecture freedom:** You design the VLANs, the BGP peering, the firewall rules. No cloud VPC constraints, no security group limits, no NAT gateway costs.

### 4.3 What You Lose On-Prem

1. **Operational burden:** etcd management, certificate rotation monitoring, API server availability — these are your problem. A 3 AM page about etcd quorum loss has no cloud support ticket to file.

2. **No managed upgrades:** Cloud providers perform control plane upgrades in-place with rollback capability. On-prem, you're rolling binary upgrades across nodes and hoping your backup strategy is solid.

3. **No SLA:** Your availability is bounded by your hardware, power, and network reliability. There's no 99.95% guarantee from a provider.

4. **Scaling ceiling:** Adding control plane capacity means provisioning new hardware. In the cloud, the provider auto-scales transparently.

### 4.4 EKS-Specific Architectural Notes

- EKS runs the control plane in an **AWS-managed VPC** separate from your worker node VPC. The API server endpoint is exposed via an NLB that spans AZs
- EKS uses **ENI** (Elastic Network Interface) injection into your VPC for API server → kubelet communication
- Authentication uses **aws-iam-authenticator** or OIDC — no client certificates by default
- Pod identity uses **IRSA** (IAM Roles for Service Accounts) or the newer **EKS Pod Identity Agent**
- `aws-node` DaemonSet (VPC CNI) manages pod IP allocation from your VPC CIDR — pods get real VPC IPs

### 4.5 GKE-Specific Architectural Notes

- GKE **Standard** gives you node management control; **Autopilot** manages nodes for you
- GKE runs control plane in Google's infrastructure, not your project's VPC
- **Workload Identity Federation** maps Kubernetes ServiceAccounts to Google Cloud IAM — the recommended auth model
- GKE uses a custom CNI (Dataplane V2, based on Cilium with eBPF) in newer clusters
- **GKE Autopilot** enforces Pod Security Standards and resource requests/limits — you cannot run privileged pods

### 4.6 AKS-Specific Architectural Notes

- AKS control plane is free (standard tier); premium tier adds uptime SLA and API server autoscaling
- **Azure AD integration** provides OIDC authentication — the recommended auth model
- AKS uses **Azure CNI** (pods get Azure VNET IPs) or **Azure CNI Overlay** (pods get overlay IPs)
- **AKS managed identity** replaces service principals for Azure resource access
- Node pools use **Azure Virtual Machine Scale Sets (VMSS)** with configurable auto-scaling

---

## 5. Follow-Along Exercise: Bootstrapping a 3-Node RKE2 Cluster with kube-vip

### 5.1 Architecture Overview

This exercise builds a 3-node HA RKE2 cluster with:
- Embedded etcd (3-member quorum)
- kube-vip in ARP mode for the API VIP (`10.20.10.10`)
- `cni: none` (Cilium will be installed in Chapter 4)
- Shared constants consumed by both OpenTofu and Ansible

### 5.2 Prerequisites

- 3 Linux nodes (Ubuntu 24.04 LTS recommended) with:
  - 4+ CPU cores, 8+ GB RAM, 50+ GB SSD (NVMe preferred for etcd)
  - `eth0` on VLAN 10 (`10.20.10.0/24`)
  - Static IPs: `10.20.10.11`, `10.20.10.12`, `10.20.10.13`
- Ansible installed on operator workstation
- OpenTofu installed on operator workstation
- DNS record: `k8s-api.lab.home.arpa → 10.20.10.10`

### 5.3 File Structure

```
platform-expert-kubernetes-at-scale/src/chapter_01/
├── constants.yaml                    # Shared constants (single source of truth)
├── ansible/
│   ├── inventory.ini                 # Lab inventory
│   ├── playbooks/
│   │   ├── 01-host-prep.yml          # OS-level prerequisites
│   │   ├── 02-rke2-install.yml       # RKE2 binary install
│   │   └── 03-rke2-bootstrap.yml     # Cluster formation
│   └── roles/
│       ├── host_prep/
│       │   └── tasks/main.yml
│       ├── rke2_install/
│       │   └── tasks/main.yml
│       └── rke2_bootstrap/
│           ├── tasks/main.yml
│           └── templates/
│               ├── config.yaml.j2
│               └── kube-vip.yaml.j2
└── tofu/
    ├── main.tf                       # DNS record for API VIP
    ├── variables.tf
    ├── outputs.tf
    └── providers.tf
```

### 5.4 Step-by-Step Instructions

All files referenced below are saved in `./platform-expert-kubernetes-at-scale/src/chapter_01/`. Apply them in order.

#### Step 1: Review Shared Constants

The `constants.yaml` file is the single source of truth for network configuration. Both Ansible and OpenTofu consume it directly. **Never duplicate these values.**

→ See: `src/chapter_01/constants.yaml`

#### Step 2: Prepare the Ansible Inventory

The inventory groups nodes into `first_server` (bootstrap node), `servers` (all control-plane nodes), and `agents` (worker-only nodes).

→ See: `src/chapter_01/ansible/inventory.ini`

#### Step 3: Run Host Preparation

This playbook configures kernel modules, sysctl settings, and firewall rules required by RKE2 and Kubernetes networking.

```bash
cd platform-expert-kubernetes-at-scale/src/chapter_01/
ansible-playbook -i ansible/inventory.ini ansible/playbooks/01-host-prep.yml
```

→ See: `src/chapter_01/ansible/playbooks/01-host-prep.yml` and `src/chapter_01/ansible/roles/host_prep/tasks/main.yml`

#### Step 4: Install RKE2 Binary

This playbook downloads and installs a **pinned** RKE2 version. Never use floating channels in production.

```bash
ansible-playbook -i ansible/inventory.ini ansible/playbooks/02-rke2-install.yml
```

→ See: `src/chapter_01/ansible/playbooks/02-rke2-install.yml` and `src/chapter_01/ansible/roles/rke2_install/tasks/main.yml`

#### Step 5: Bootstrap the Cluster

This is the critical playbook. It:
1. Renders the RKE2 config (with `cni: none` and `tls-san` for the VIP)
2. Deploys the kube-vip static pod manifest on all server nodes
3. Starts the first server to initialize etcd and generate the join token
4. Joins remaining servers to form the HA cluster

```bash
ansible-playbook -i ansible/inventory.ini ansible/playbooks/03-rke2-bootstrap.yml
```

→ See: `src/chapter_01/ansible/playbooks/03-rke2-bootstrap.yml` and `src/chapter_01/ansible/roles/rke2_bootstrap/`

#### Step 6: Verify the Cluster

After bootstrap completes:

```bash
# Copy kubeconfig from the first server
scp node-01:/etc/rancher/rke2/rke2.yaml ~/.kube/config
# Update the server URL to use the VIP
sed -i 's|https://127.0.0.1:6443|https://10.20.10.10:6443|' ~/.kube/config

# Verify all nodes are Ready (they'll be NotReady until CNI is installed)
kubectl get nodes -o wide

# Verify etcd health
kubectl -n kube-system exec -it etcd-gmk-node-01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  endpoint status --write-out=table

# Verify etcd member list
kubectl -n kube-system exec -it etcd-gmk-node-01 -- etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cert=/var/lib/rancher/rke2/server/tls/etcd/server-client.crt \
  --key=/var/lib/rancher/rke2/server/tls/etcd/server-client.key \
  --cacert=/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt \
  member list --write-out=table

# Verify kube-vip VIP is responding
curl -k https://10.20.10.10:6443/healthz
# Expected: ok

# Verify from any machine on VLAN 10
ping 10.20.10.10
# Verify ARP resolution
arp -n | grep 10.20.10.10
```

#### Step 7: (Optional) Create DNS Record with OpenTofu

If you manage DNS via a provider with API access (e.g., Cloudflare for a public domain), you can use OpenTofu to create the API DNS record.

→ See: `src/chapter_01/tofu/` for example Cloudflare DNS configuration

```bash
cd platform-expert-kubernetes-at-scale/src/chapter_01/tofu/
tofu init
tofu plan
tofu apply
```

**Note:** For private `home.arpa` DNS (as in the reference architecture), the DNS record is created manually on the Synology DNS Server. OpenTofu is used here only to demonstrate the shared-constants pattern.

---

## 6. Interview Questions

### Staff/Senior-Level Control Plane & Bootstrap Interview Questions

**Q1: Explain the Raft consensus protocol's leader election mechanism. What happens when a follower's election timeout expires?**

*Expected answer:* When a follower hasn't received a heartbeat from the leader within its randomized election timeout, it increments its term, transitions to candidate state, votes for itself, and sends RequestVote RPCs to all peers. A candidate becomes leader upon receiving votes from a majority. The randomized timeout prevents election storms. If no candidate wins (split vote), timeouts reset with new random values and the process repeats. The term mechanism acts as a logical clock — any message with a higher term causes the recipient to update its term and revert to follower state.

---

**Q2: Why is a 2-node etcd cluster worse than a 1-node cluster for availability?**

*Expected answer:* With 2 nodes, quorum requires both nodes (⌊2/2⌋ + 1 = 2). Losing either node means no writes can be committed. With 1 node, you have no fault tolerance but also no second node that can independently cause failure. A 2-node cluster has doubled the failure domain without gaining any fault tolerance — the probability of losing quorum has actually increased because either node failing is catastrophic.

---

**Q3: Describe the full request lifecycle when a user runs `kubectl apply -f deployment.yaml`, from client to etcd commit.**

*Expected answer:* (1) kubectl serializes the Deployment to JSON/protobuf and sends an HTTP PUT/PATCH to the API server. (2) API server authenticates via the kubeconfig's credentials (cert, token, or OIDC). (3) RBAC authorization check — does this identity have permission to create/update Deployments in this namespace? (4) Mutating admission webhooks fire — they can modify the object (inject sidecars, add labels). (5) Schema validation — is the object valid per the Deployment OpenAPI spec? (6) Validating admission webhooks fire — they can reject but not modify. (7) ValidatingAdmissionPolicy (CEL) runs in-process. (8) Optimistic concurrency check — if updating, does the resourceVersion match? (9) The object is serialized to protobuf and written to etcd via the API server's etcd client. (10) etcd leader proposes the write via Raft, replicates to quorum, commits, responds. (11) API server returns success to kubectl. (12) The watch cache notifies the Deployment controller, which creates a ReplicaSet, which creates Pods, which the scheduler then binds to nodes.

---

**Q4: What is the watch cache in the API server, and why is it critical for cluster scalability?**

*Expected answer:* The watch cache is an in-memory ring buffer in the API server that stores recent object revisions. When controllers issue WATCH requests, they read from this cache instead of hitting etcd. Without it, hundreds of controllers watching thousands of resources would generate unsustainable load on etcd. The watch cache uses the etcd revision number as its index, allowing clients to resume watches from a specific revision. If a client's bookmark revision has been compacted from the cache, the API server returns a `410 Gone` error, forcing a full re-list.

---

**Q5: You notice that `etcd_disk_wal_fsync_duration_seconds` p99 is consistently above 25ms. What is happening and what do you do?**

*Expected answer:* The WAL fsync latency directly measures how long it takes to persist a Raft log entry to disk. At 25ms p99, the disk is too slow for etcd's requirements. This will cause increased write latency, potential leader instability (if fsync latency approaches the heartbeat interval of 100ms), and eventually election storms. Immediate actions: (1) Check if the disk is shared with other I/O-heavy workloads — etcd should have a dedicated volume. (2) Verify the disk type — spinning disks are unacceptable; SSDs with power-loss protection are required. (3) Check the I/O scheduler — `none` or `mq-deadline` for NVMe. (4) Check for noisy neighbors in VM environments using `iostat -x`. (5) If running on a VM, check for I/O throttling at the hypervisor level. The target is <10ms p99 for WAL fsync.

---

**Q6: Explain how kube-vip ARP mode achieves API server failover. What is a Gratuitous ARP and why is it necessary?**

*Expected answer:* kube-vip runs on each control-plane node and performs leader election. The leader adds the VIP as a secondary IP address on its network interface using netlink and sends a Gratuitous ARP (GARP) — an ARP request where both sender and target protocol addresses are the VIP. The GARP is broadcast to all devices on the L2 segment, causing them to update their ARP caches to map the VIP to the new leader's MAC address. When the leader fails, a new leader is elected, binds the VIP, sends a new GARP, and traffic flows to the new node. GARP is necessary because without it, other hosts would continue sending traffic to the old leader's MAC address until their ARP cache entries expire naturally (which can take minutes).

---

**Q7: What is the difference between etcd's WAL and its bbolt database? Why does etcd need both?**

*Expected answer:* The WAL (Write-Ahead Log) is an append-only, sequential log of Raft entries. Every committed entry is written to the WAL first with an fsync. The bbolt database is a B+ tree that stores the actual key-value data with MVCC versioning. etcd needs both because: (1) WAL provides crash recovery — if the process crashes after a WAL write but before the bbolt commit, the WAL entry is replayed on restart. (2) WAL writes are sequential and fast; bbolt writes are random and slower. (3) bbolt provides efficient point and range queries; the WAL alone would require replaying the entire log. (4) Snapshots periodically capture the bbolt state, allowing the WAL to be truncated. They serve complementary purposes: WAL for durability and ordering, bbolt for queryable state.

---

**Q8: In RKE2, the control plane runs as static pods. What are the implications of this for debugging and lifecycle management compared to systemd services?**

*Expected answer:* Static pods are managed by kubelet directly from manifest files in `/var/lib/rancher/rke2/agent/pod-manifests/`. Implications: (1) You can't `kubectl delete` a static pod — kubelet will immediately recreate it. To stop a component, you must remove or rename its manifest file. (2) Logs are accessible via `kubectl logs` or `crictl logs`, not `journalctl -u etcd`. (3) Resource limits are enforced via cgroups, managed by kubelet's cgroup driver. (4) Liveness/readiness probes are managed by kubelet. (5) Upgrades happen by RKE2 replacing the manifest and image — kubelet detects the change and recreates the pod. (6) If kubelet itself crashes, all static pods stop. This is a shared-fate dependency. (7) Static pods appear in `kubectl get pods -n kube-system` with a `-<nodename>` suffix but are mirror pods — the API server doesn't control them.

---

**Q9: Describe etcd's MVCC model. How does Kubernetes use `resourceVersion` to implement optimistic concurrency, and what happens on a conflict?**

*Expected answer:* etcd uses Multi-Version Concurrency Control where every write creates a new revision (a monotonically increasing 64-bit integer) rather than overwriting existing data. In Kubernetes, the `resourceVersion` field on every object corresponds to the etcd modification revision. When a client sends an update, the API server performs a conditional write: "write this new value only if the current revision matches the provided resourceVersion." If another writer modified the object in the meantime (different revision), etcd returns a compare failure, the API server returns HTTP 409 Conflict, and the client must re-read the object, re-apply its changes, and retry. Controllers implement this as a read-modify-write retry loop. This eliminates the need for distributed locks while preventing lost updates.

---

**Q10: Why does RKE2 use `cni: none` in the bootstrap strategy described in this chapter? What breaks if you install a CNI before kube-vip?**

*Expected answer:* RKE2's `cni: none` allows the operator to install a custom CNI (like Cilium) separately. In this architecture, kube-vip must start before the CNI because it provides the API VIP. kube-vip in ARP mode runs with `hostNetwork: true` and has no dependency on pod networking. If you installed a CNI like Cilium first, it would need to connect to the API server — but without kube-vip's VIP, the API endpoint is a single node IP, which defeats HA. The correct order is: (1) start RKE2 with `cni: none`, (2) deploy kube-vip to establish the stable VIP, (3) install the CNI. Nothing technically "breaks" if CNI is installed first, but the cluster lacks a stable API endpoint until kube-vip is running.

---

**Q11: What are the security implications of running control plane components with `hostNetwork: true`?**

*Expected answer:* `hostNetwork: true` means the container shares the host's network namespace. Implications: (1) The component can bind to any port on the host — port conflicts with host services are possible. (2) It can see all network traffic on the host's interfaces (if it has `CAP_NET_RAW`). (3) It bypasses NetworkPolicy — CNI-enforced policies apply to pods with their own network namespace, not hostNetwork pods. (4) Any vulnerability in a hostNetwork pod that allows arbitrary network access gives the attacker the same network position as the host itself. (5) It can access services on `localhost` of the host, including other hostNetwork pods. This is acceptable for control plane components because they are trusted system components, but it's a risk that must be understood. CIS benchmarks flag unnecessary hostNetwork usage.

---

**Q12: How does the API server's API Priority and Fairness (APF) system prevent a misbehaving controller from starving the cluster?**

*Expected answer:* APF classifies incoming requests into flow schemas based on attributes like user, namespace, and verb. Each flow schema maps to a priority level. Each priority level has a configured concurrency share (number of concurrent request slots). Within a priority level, requests are queued with fair queuing — each flow gets a proportional share of the concurrency slots. If a CRD controller floods the API server with list requests, APF confines that traffic to its flow's queue within its priority level, preventing it from consuming slots reserved for system-critical flows (like kubelet heartbeats or controller-manager reconciliation). Without APF, a single misbehaving client could exhaust the API server's connection pool and effectively DoS the cluster.

---

**Q13: You have a 3-node etcd cluster and need to replace a failed member. Describe the exact procedure and explain what happens to quorum during the process.**

*Expected answer:* (1) The failed member must first be removed from the cluster membership using `etcdctl member remove <ID>`. This reduces the cluster to 2 members, with quorum at 2 — the cluster is now operating with zero fault tolerance. (2) Provision a new node. (3) Use `etcdctl member add <name> --peer-urls=https://<new-ip>:2380` to add the new member. (4) Start etcd on the new node with `--initial-cluster-state=existing`. (5) The new member joins, receives a snapshot from a healthy member, and begins receiving Raft log entries. During step 1-4, the cluster has only 2 members and quorum of 2 — losing another node means total outage. This is why (a) replacement should be fast, and (b) 5-node clusters are preferred if member replacement is slow. In RKE2, the process is similar but managed through `rke2 server` with the appropriate join configuration.

---

**Q14: Explain the relationship between the ServiceAccount token signing key and the API server. What happens if you lose this key and regenerate it?**

*Expected answer:* The API server uses an RSA or ECDSA private key (`--service-account-signing-key-file`) to sign JWT tokens for ServiceAccounts. The corresponding public key (`--service-account-key-file`) is used to verify tokens. If you lose the signing key and regenerate it, every existing ServiceAccount token in the cluster becomes invalid because the new key produces a different signature. Every pod that authenticates to the API server via its projected ServiceAccount token will receive 401 Unauthorized responses. This effectively breaks all in-cluster authentication: controllers can't reconcile, CNI pods can't configure networking, DNS can't resolve. Recovery requires restarting all pods so they receive new tokens signed by the new key. This is why the signing key must be backed up alongside etcd snapshots.

---

**Q15: What is the "split-brain" scenario for kube-vip ARP mode, and under what physical network conditions can it occur?**

*Expected answer:* True Raft split-brain is impossible, but kube-vip's ARP mode can experience an L2 split-brain if the network is partitioned within a single VLAN. If a switch failure or misconfigured trunk creates two L2 segments where each segment has at least one kube-vip instance, and the instances can't communicate (so each segment elects its own leader), two nodes may both claim the VIP. Clients on each segment see a different MAC for the VIP. This causes: (1) clients connect to different API servers depending on their segment, (2) one segment's leader may be communicating with stale etcd state, (3) writes from both segments may conflict. This scenario is rare on a single, well-configured switch but possible with stacked switches or spanning-tree misconfiguration. Mitigation: use a dedicated, flat L2 segment for the management VLAN and monitor for duplicate ARP responses.

---

**Q16: How does etcd compaction work, and what happens if compaction is disabled or falls too far behind?**

*Expected answer:* etcd compaction removes historical key revisions up to a specified revision, reclaiming space from old MVCC versions. Auto-compaction can be periodic (delete revisions older than X) or revision-based. If compaction is disabled: (1) the database grows unbounded as every write creates a new revision. (2) When the database exceeds `--quota-backend-bytes` (default 2 GB in etcd, 8 GB in RKE2), etcd triggers a space alarm and refuses all writes. (3) Kubernetes becomes read-only — no pod scheduling, no deployments, no mutations. (4) Recovery requires running `etcdctl compact <revision>`, then `etcdctl defrag`, then `etcdctl alarm disarm`. If compaction falls behind but hasn't hit the quota, watch clients may request revisions that have been compacted, receiving `ErrCompacted` and needing to re-list, which puts additional load on both etcd and the API server.

---

**Q17: Describe the exact TLS handshake sequence when a kubelet connects to the API server via the kube-vip VIP. Which certificates are involved?**

*Expected answer:* (1) Kubelet opens a TCP connection to `10.20.10.10:6443`. ARP resolves this to the kube-vip leader's MAC. (2) TLS ClientHello from kubelet. (3) API server responds with its serving certificate (which has SAN: `10.20.10.10`, `k8s-api.lab.home.arpa`, etc.). (4) Kubelet validates the API server cert against the cluster CA stored in `/var/lib/rancher/rke2/agent/server-ca.crt`. (5) If mutual TLS, kubelet presents its client certificate (issued by the cluster CA, with O=system:nodes, CN=system:node:<hostname>). (6) API server validates kubelet's cert against the CA. (7) TLS session established. (8) Kubelet authenticates as the node identity via the client cert. (9) RBAC authorizes the kubelet's requests via the `system:node` ClusterRole binding. The VIP is transparent at the TLS level — what matters is that the VIP IP is in the API server cert's SANs.

---

**Q18: What is the difference between `etcdctl snapshot save` and an etcd learner node in terms of backup strategy?**

*Expected answer:* `etcdctl snapshot save` creates a point-in-time consistent snapshot of the entire bbolt database. It's the standard backup mechanism — you get a single file that can restore the complete cluster state. A learner node is a non-voting etcd member that receives the Raft log but doesn't participate in quorum. Learners are used for adding new members safely (they catch up before becoming voters) or for streaming backups (you can snapshot the learner without impacting the quorum's performance). Key differences: (1) Snapshots are static, point-in-time; learners maintain a continuously replicated copy. (2) Snapshots are simpler but have RPO equal to the snapshot interval. (3) Learner-based backup has near-zero RPO but adds operational complexity. (4) Snapshot restore creates a new single-member cluster from the file; learner-based recovery maintains membership. For most homelab and small production clusters, periodic `etcdctl snapshot save` to an off-cluster target (like Synology S3) is the right choice.

---

**Q19: Explain how the kube-scheduler's scoring plugins work. If you have two nodes that both pass filtering, how does the scheduler decide between them?**

*Expected answer:* After the filter phase eliminates ineligible nodes, the score phase runs scoring plugins. Each plugin assigns a score (0-100) to each candidate node. Scores are then weighted by the plugin's configured weight and summed. The node with the highest total score wins. Built-in scoring plugins include: `NodeResourcesBalancedAllocation` (favors nodes where CPU/memory utilization is balanced), `NodeResourcesFit` (variant: `LeastAllocated` or `MostPacked`), `InterPodAffinity` (rewards colocation), `NodeAffinity` (rewards preferred affinities), `TaintToleration` (penalizes tolerated taints), `ImageLocality` (favors nodes that already have the container image). If scores are tied, the scheduler uses a random selection. The plugin framework is extensible — custom schedulers can add scoring plugins without forking the scheduler.

---

**Q20: You need to move from ARP-mode kube-vip to BGP-mode for the API VIP. Describe the migration plan and the risks.**

*Expected answer:* (1) Ensure Cilium is running and BGP peering is established with the upstream router. (2) Configure kube-vip BGP mode with the router's ASN and peer IP. (3) The critical moment is the switchover: you need to transition from single-leader ARP to multi-node BGP advertisement. Options: (a) Rolling reconfiguration — update kube-vip on one node at a time, switching from ARP to BGP. Risk: during transition, some nodes advertise via ARP and others via BGP, potentially causing traffic asymmetry. (b) Parallel VIP — allocate a new VIP for BGP, update kubeconfig and certificates to use the new VIP, then decommission the ARP VIP. This is safer but requires certificate re-issuance with new SANs. Risks: (1) If BGP peering drops, the VIP becomes unreachable (unlike ARP which only needs L2). (2) Router misconfiguration could blackhole traffic. (3) ECMP hashing changes during the migration may cause TCP connection resets. The parallel VIP approach is recommended.

---

**Q21: What happens to running workloads when the entire control plane goes down (all 3 nodes lose power)?**

*Expected answer:* Existing pods continue running. kubelet on each node continues managing the containers it already has. The container runtime (containerd) doesn't depend on the control plane. However: (1) No new pods can be scheduled. (2) No deployments can be updated. (3) No horizontal scaling occurs. (4) Failed pods are not replaced (ReplicaSet controller is down). (5) Node-level issues are not handled (node controller is down). (6) DNS updates stop (CoreDNS can't update if it needs to, though existing entries keep working). (7) Service endpoint updates stop — if a pod IP changes, services won't route correctly. (8) Certificate renewal stops — if any cert expires during the outage, TLS-dependent communication fails when the control plane comes back. The cluster is in a "brain-dead" state: alive but unmanaged. The window of survivability depends on workload stability and certificate expiry.

---

**Q22: Explain the implications of `--quota-backend-bytes` in etcd. How do you size this parameter, and what happens when the quota is exceeded?**

*Expected answer:* `--quota-backend-bytes` sets the maximum size of the etcd bbolt database file. When exceeded, etcd raises a `NOSPACE` alarm and becomes read-only — all write proposals are rejected. In Kubernetes, this means: API server can serve reads but rejects all mutations. Sizing depends on: (1) Number of Kubernetes objects — each object is ~1-10 KB. (2) CRD volume — some controllers create thousands of CRD instances. (3) Secret/ConfigMap size — large secrets inflate the database. (4) Watch history — MVCC revisions between compaction cycles. RKE2 defaults to 8 GB, which is generous for most clusters. A healthy 200-node cluster typically uses 1-4 GB. Recovery: `etcdctl compact <revision>`, `etcdctl defrag --endpoints=<all-members>`, `etcdctl alarm disarm`. Prevention: monitor `etcd_mvcc_db_total_size_in_bytes` and alert at 80% of quota.

---

**Q23: How does RKE2's embedded etcd differ from running etcd as an external cluster? What are the trade-offs?**

*Expected answer:* Embedded etcd runs as a static pod on each RKE2 server node — etcd membership is automatically managed based on RKE2 server joins/leaves. External etcd runs as a separate cluster on dedicated nodes (or VMs) managed independently. Trade-offs: (1) **Resource contention:** Embedded etcd shares node resources with the API server, scheduler, controller-manager, and potentially workloads. Disk I/O contention between etcd WAL writes and other workloads is the primary risk. External etcd on dedicated hardware eliminates this. (2) **Operational simplicity:** Embedded is dramatically simpler — no separate etcd cluster to manage, backup, and upgrade. RKE2 handles the lifecycle. (3) **Failure blast radius:** With embedded etcd, losing a node loses both a control plane member and an etcd member simultaneously. With external etcd, control plane and data plane failures are independent. (4) **Scaling:** External etcd can be sized independently (5 etcd nodes + 3 API servers). Embedded couples the two. For homelab and small production (3-5 nodes), embedded is the right choice. For large clusters (100+ nodes) or regulated environments, external etcd on dedicated nodes with NVMe storage is preferred.

---

**Q24: What is the purpose of the front-proxy CA in a Kubernetes cluster? When is it used?**

*Expected answer:* The front-proxy CA signs the client certificate that the API server uses when proxying requests to aggregated API servers (like metrics-server). When a client requests a resource handled by an aggregated API server (e.g., `kubectl top nodes` → `metrics.k8s.io`), the kube-apiserver acts as a reverse proxy: it receives the request, authenticates the client normally, then forwards the request to the aggregated API server. The forwarded request includes the front-proxy client certificate for the aggregated API server to trust, plus `X-Remote-User` and `X-Remote-Group` headers carrying the original client's identity. The aggregated API server validates the front-proxy cert against the front-proxy CA to ensure the request genuinely came from the main API server and not a spoofed source. Without a valid front-proxy setup, aggregated APIs won't work — `kubectl top` fails, custom API servers return auth errors.

---

**Q25: Design a monitoring and alerting strategy for a 3-node on-premises etcd cluster. What are the top 5 metrics to monitor, what thresholds trigger alerts, and what runbook actions do you take for each?**

*Expected answer:*

| # | Metric | Warning Threshold | Critical Threshold | Runbook Action |
|---|--------|-------------------|-------------------|----------------|
| 1 | `etcd_disk_wal_fsync_duration_seconds` (p99) | >10ms | >25ms | Check disk type, I/O scheduler, noisy neighbors. Move etcd to dedicated NVMe if shared. |
| 2 | `etcd_server_leader_changes_seen_total` (rate) | >1/hr | >3/hr | Indicates disk pressure or network instability. Check WAL latency, network RTT between members. Check for clock skew. |
| 3 | `etcd_mvcc_db_total_size_in_bytes` | >70% of quota | >85% of quota | Run compaction and defrag. Investigate if a controller is creating excessive objects. Check auto-compaction config. |
| 4 | `etcd_network_peer_round_trip_time_seconds` (p99) | >5ms | >50ms | Check network path between etcd members. Look for switch congestion, MTU issues, or intermediate firewalls adding latency. |
| 5 | `etcd_server_proposals_failed_total` (rate) | >0 sustained | >5/min | Failed proposals indicate quorum issues. Check member health, leader stability, and whether any member is partitioned. Take an etcd snapshot immediately as a precaution. |

Additionally: alert if any member is unreachable (`etcd_server_has_leader == 0`), and always take a snapshot before any maintenance window.

---

## Sources

- [Raft Consensus Algorithm](https://raft.github.io/)
- [etcd Documentation — Performance](https://etcd.io/docs/v3.2/op-guide/performance/)
- [etcd Persistent Storage Files](https://etcd.io/docs/v3.6/learning/persistent-storage-files/)
- [bbolt — Embedded Key/Value Database for Go](https://github.com/etcd-io/bbolt)
- [RKE2 Architecture](https://docs.rke2.io/architecture)
- [RKE2 Embedded Datastore](https://docs.rke2.io/datastore/embedded)
- [RKE2 Static Pod Management](https://deepwiki.com/rancher/rke2/2.2-static-pod-management)
- [kube-vip ARP Mode](https://kube-vip.io/docs/modes/arp/)
- [kube-vip Architecture](https://kube-vip.io/docs/about/architecture/)
- [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/)
- [Kubernetes Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Kubernetes Dynamic Admission Control](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/)
- [Kubernetes API Server Internals](https://www.kubenatives.com/p/kubernetes-api-server-internals)
- [Talos Linux](https://www.talos.dev/)
- [Talos Linux vs K3s](https://www.siderolabs.com/blog/talos-linux-vs-k3s/)
- [RKE2 vs K3s](https://oneuptime.com/blog/post/2026-03-20-rke2-vs-k3s/view)
- [EKS vs AKS vs GKE](https://www.sentinelone.com/cybersecurity-101/cybersecurity/eks-vs-aks-vs-gke/)
- [Managed Kubernetes Compared](https://www.naviteq.io/blog/oke-vs-eks-vs-gke-vs-aks-kubernetes-compared/)
- [Operating etcd in Production](https://medium.com/@firmanbrilian/operating-etcd-in-production-performance-tuning-monitoring-and-backup-strategies-3dc690731df8)
- [etcd Performance Optimization — Alibaba Cloud](https://www.alibabacloud.com/blog/596294)
