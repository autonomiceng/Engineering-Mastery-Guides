# Chapter 2: GitOps, Fleet Management & Secrets

> *"GitOps is not a tool. It is the operating model where Git is the single source of truth for declarative infrastructure and applications."*

---

## 1. Title & Deep Dive

### 1.1 The GitOps Operating Model

GitOps is a set of practices that uses Git as the single source of truth for declarative infrastructure and application configuration. The core contract:

1. **Declarative:** The entire desired system state is described declaratively (Kubernetes manifests, Helm values, Kustomize overlays)
2. **Versioned and immutable:** The desired state is stored in Git, providing an immutable audit trail with full history
3. **Pulled automatically:** Software agents (ArgoCD, Flux) automatically pull the desired state from Git and apply it
4. **Continuously reconciled:** Agents continuously compare actual state with desired state and correct drift

This inverts the traditional CI/CD push model. Instead of a pipeline pushing changes into a cluster, the cluster pulls its own state from Git. This distinction matters for security (the cluster needs read access to Git, not the other way around), for auditability (every change is a Git commit), and for disaster recovery (rebuild the cluster, point it at Git, and the entire platform reconverges).

### 1.2 ArgoCD: Architecture Deep Dive

ArgoCD is a declarative, GitOps continuous delivery tool for Kubernetes. As of 2026, it is the dominant GitOps tool in the CNCF ecosystem, with over 64% enterprise adoption for primary delivery mechanisms.

#### 1.2.1 Core Components

ArgoCD runs as a set of controllers and services inside the Kubernetes cluster:

| Component | Role | Scaling Notes |
|-----------|------|---------------|
| **argocd-server** | API server + UI + gRPC/REST gateway | Stateless; horizontally scalable behind a load balancer |
| **argocd-repo-server** | Clones Git repos, renders manifests (Helm, Kustomize, plain YAML) | CPU/memory intensive; scale based on repo count and manifest complexity |
| **argocd-application-controller** | Watches Application CRDs, compares desired vs live state, triggers sync | Single active instance with leader election; sharding available for large-scale |
| **argocd-applicationset-controller** | Generates Application CRDs from ApplicationSet templates | Single instance; lightweight |
| **argocd-notifications-controller** | Sends notifications on sync events (Slack, webhook, email) | Single instance |
| **argocd-dex-server** | OIDC/SSO authentication proxy | Optional; used for external identity providers |
| **Redis** | Caching layer for repo-server manifest renders and live state | In-memory; critical for performance at scale |

**Architectural invariant:** ArgoCD never pushes credentials into a cluster. The cluster agent pulls manifests from Git and applies them via the Kubernetes API. This is the fundamental difference from CI/CD pipeline tools that `kubectl apply` from an external runner.

#### 1.2.2 The Reconciliation Loop

ArgoCD's reconciliation is the heartbeat of the GitOps model:

```
Every 3 minutes (configurable via --app-resync):
  1. Application Controller reads each Application CRD
  2. Repo Server clones/fetches the target Git repo at the specified revision
  3. Repo Server renders manifests:
     - Helm: helm template with values files
     - Kustomize: kustomize build with overlays
     - Plain YAML: directory listing
     - KSOPS: decrypt SOPS-encrypted resources during kustomize build
  4. Application Controller computes a 3-way diff:
     - Desired state (from Git, rendered)
     - Live state (from Kubernetes API, cached)
     - Last-applied state (from annotation or tracking method)
  5. If diff exists → Application status = OutOfSync
  6. If auto-sync enabled → trigger sync (apply manifests)
  7. If self-heal enabled → revert manual cluster changes
  8. Health assessment runs on all managed resources
  9. Status updated on the Application CRD
```

**Diff detection methods:**

| Method | How It Works | Pros | Cons |
|--------|-------------|------|------|
| **3-way merge** (default) | Compares desired, live, and last-applied annotation | Ignores fields set by controllers (like `status`) | Annotation-based; can be confused by external mutators |
| **Server-side diff** (v2.5+) | Uses API server dry-run to compute diff | Most accurate; handles defaulting and admission webhooks | Slightly higher API server load |
| **Structured merge diff** | Uses strategic merge patches | Handles list merges correctly | More complex |

#### 1.2.3 Application and ApplicationSet

**Application** is ArgoCD's fundamental unit of deployment:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: argocd
spec:
  project: platform
  source:
    repoURL: https://github.com/org/k8s-platform.git
    targetRevision: main
    path: k8s/platform/cert-manager
  destination:
    server: https://kubernetes.default.svc
    namespace: cert-manager
  syncPolicy:
    automated:
      prune: true          # Delete resources removed from Git
      selfHeal: true       # Revert manual cluster changes
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**ApplicationSet** is the templating engine that generates Applications dynamically:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-apps
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/org/k8s-platform.git
        revision: main
        directories:
          - path: k8s/platform/*
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: platform
      source:
        repoURL: https://github.com/org/k8s-platform.git
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
```

**Generator types:**

| Generator | Use Case |
|-----------|----------|
| **List** | Explicit list of clusters/environments |
| **Cluster** | Discover clusters registered in ArgoCD |
| **Git Directory** | One Application per directory in a repo path |
| **Git File** | Generate from YAML/JSON files in Git |
| **Matrix** | Cartesian product of two generators |
| **Merge** | Overlay generator outputs |
| **Pull Request** | Create Applications for open PRs (preview environments) |
| **SCM Provider** | Discover repos from GitHub/GitLab organizations |

#### 1.2.4 Progressive Syncs

ApplicationSets support progressive sync — rolling out changes across Applications in stages:

```yaml
spec:
  strategy:
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions:
            - key: env
              operator: In
              values: [staging]
          maxUpdate: 1
        - matchExpressions:
            - key: env
              operator: In
              values: [production]
          maxUpdate: 25%
```

Each step waits for all Applications in the current stage to become `Healthy` before proceeding to the next. This enables canary-style rollouts across clusters.

#### 1.2.5 Sync Waves and Hooks

ArgoCD supports ordering within a single Application via **sync waves** and **resource hooks**:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # Negative = earlier
    argocd.argoproj.io/hook: PreSync     # Run before main sync
```

| Hook | When It Runs |
|------|-------------|
| `PreSync` | Before the main sync (database migrations, secret provisioning) |
| `Sync` | During the main sync (default for all resources) |
| `PostSync` | After all sync resources are healthy (smoke tests, notifications) |
| `SyncFail` | If the sync fails (cleanup, alerting) |
| `Skip` | Resource is never applied by ArgoCD |

**Sync wave ordering:** Resources with lower wave numbers sync first. Within a wave, ArgoCD syncs Namespaces first, then CRDs, then other resources. This is critical for bootstrap ordering — you need the namespace and CRDs to exist before the operator and CRs that depend on them.

#### 1.2.6 ArgoCD Projects

Projects provide multi-tenancy within ArgoCD:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: platform
  namespace: argocd
spec:
  description: Platform infrastructure components
  sourceRepos:
    - https://github.com/org/k8s-platform.git
  destinations:
    - namespace: '*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: '*'
      kind: '*'
  namespaceResourceWhitelist:
    - group: '*'
      kind: '*'
```

Projects control:
- Which Git repos can be used as sources
- Which clusters and namespaces can be targeted
- Which Kubernetes resource types can be created
- Role-based access within ArgoCD

### 1.3 Rancher: Cluster Management and Fleet

#### 1.3.1 Rancher Architecture

Rancher is a multi-cluster Kubernetes management platform. In this architecture, it serves as the **management UI and observability layer**, while ArgoCD remains the **delivery owner** for GitOps.

**Key architectural principle:** Rancher is **not** a second write path. It provides visibility, RBAC management, and cluster lifecycle operations. It does not manage in-cluster manifests in namespaces that ArgoCD owns. This is an explicit boundary in the reference architecture.

Rancher's components:

| Component | Role |
|-----------|------|
| **Rancher Server** | Management plane; runs as a Deployment behind the Gateway |
| **Rancher Agent** | Runs on each managed cluster; reports status back to Rancher |
| **Fleet Manager** | Built-in GitOps engine for managing downstream clusters |
| **Fleet Agent** | Per-cluster agent that applies Fleet bundles |

#### 1.3.2 Fleet vs ArgoCD: Complementary Roles

In large SUSE/Rancher ecosystems, Fleet is the natural GitOps tool. However, this architecture uses ArgoCD for several reasons:

1. **Ecosystem independence:** ArgoCD is a CNCF Graduated project; not tied to the Rancher lifecycle
2. **Community size:** Larger community, more integrations, more documentation
3. **UI depth:** ArgoCD's diff view, resource tree, and log streaming are deeper than Fleet's UI
4. **KSOPS integration:** Mature SOPS decryption pipeline for ArgoCD exists

Fleet remains available for future multi-cluster scenarios if the architecture expands beyond a single lab cluster.

#### 1.3.3 Rancher and RBAC

Rancher extends Kubernetes RBAC with:
- **Global Roles:** Cluster-spanning permissions (admin, user, restricted-admin)
- **Cluster Roles:** Per-cluster permissions mapped to Kubernetes ClusterRoles
- **Project Roles:** Namespace-group permissions (Rancher "Projects" group namespaces)
- **External Auth:** LDAP, AD, SAML, GitHub, Google, OIDC providers

For the single-operator homelab, the primary value is: (a) a dashboard for visual cluster health, (b) easy multi-cluster registration if the architecture expands, and (c) centralized RBAC management if team members are added.

### 1.4 Secret Management: SOPS + age

#### 1.4.1 The Problem

Kubernetes Secrets are base64-encoded, not encrypted. Storing them in Git means anyone with repo access can decode them. But GitOps requires that **all** cluster state lives in Git. The secret management problem is: how do you store secrets in Git safely?

#### 1.4.2 SOPS (Secrets OPerationS)

SOPS is a CLI tool from Mozilla that encrypts/decrypts structured data files (YAML, JSON, ENV, INI). Unlike full-file encryption (like GPG on a tarball), SOPS encrypts only the **values** in a structured file, leaving keys and structure visible. This enables meaningful Git diffs on encrypted files.

**Example — a SOPS-encrypted Secret:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-repo-credentials
  namespace: argocd
type: Opaque
stringData:
  url: ENC[AES256_GCM,data:k9x2mQ==,iv:...,tag:...,type:str]
  password: ENC[AES256_GCM,data:Hf8k29x...,iv:...,tag:...,type:str]
sops:
  kms: []
  age:
    - recipient: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
      enc: |
        -----BEGIN AGE ENCRYPTED FILE-----
        YWdlLWVuY3J5cHRpb24ub3JnL3YxCi0+IFgyNTUxOSAx...
        -----END AGE ENCRYPTED FILE-----
  lastmodified: "2026-03-28T12:00:00Z"
  version: 3.9.0
```

Notice: `apiVersion`, `kind`, `metadata` — all visible. Only the values under `stringData` are encrypted. The `sops` metadata block contains the encrypted data key and recipient information.

#### 1.4.3 age: Modern Encryption

**age** (pronounced "ah-gay", Actually Good Encryption) is a simple, modern file encryption tool that replaces GPG for SOPS:

| Property | GPG | age |
|----------|-----|-----|
| Key generation | `gpg --gen-key` (interactive, complex) | `age-keygen` (one command, one line output) |
| Key format | OpenPGP keyring (complex, stateful) | Single file: public key + private key |
| Algorithm | RSA/DSA/ECDSA (configurable, footgun potential) | X25519 + ChaCha20-Poly1305 (no choices to make) |
| Key size | ~2048+ bit RSA | 32-byte X25519 |
| Identity file | `~/.gnupg/` directory tree | Single text file |
| Recipient format | `age1ql3z7hjy...` (readable, copyable) | Fingerprint hex (obtuse) |

**How SOPS + age encryption works:**

```
1. SOPS generates a random 256-bit data key
2. SOPS encrypts each value in the YAML with AES-256-GCM using the data key
3. SOPS encrypts the data key with age's X25519 + ChaCha20-Poly1305
   (the data key can be encrypted for multiple age recipients)
4. SOPS embeds the encrypted data key in the sops metadata block
5. To decrypt: age decrypts the data key → SOPS decrypts each value with AES-256-GCM
```

**Key management model:**

```
Operator workstation:
  ~/.config/sops/age/keys.txt    # Private key (NEVER in Git)

Git repo:
  .sops.yaml                     # Encryption rules + public key recipients
  k8s/secrets/*.enc.yaml         # SOPS-encrypted secrets

Kubernetes cluster (ArgoCD):
  Secret: sops-age-key           # Private key mounted into repo-server
  → KSOPS plugin decrypts during manifest rendering
```

#### 1.4.4 KSOPS: ArgoCD Integration

KSOPS (Kustomize-SOPS) is a Kustomize exec plugin that decrypts SOPS-encrypted files during `kustomize build`. ArgoCD's repo-server runs Kustomize to render manifests, and KSOPS hooks into this process:

```
ArgoCD Reconciliation:
  → Repo Server clones Git repo
  → Repo Server runs kustomize build
  → Kustomize encounters KSOPS generator
  → KSOPS calls sops --decrypt on each encrypted file
  → sops reads the age private key from the mounted Secret
  → Decrypted plaintext Secret manifests are returned to Kustomize
  → Kustomize outputs the full manifest set
  → Application Controller applies manifests to cluster
  → Plaintext Secrets exist ONLY in the cluster, never in Git
```

**Kustomize generator configuration:**

```yaml
# kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
generators:
  - secret-generator.yaml

# secret-generator.yaml
apiVersion: viaduct.ai/v1
kind: ksops
metadata:
  name: secret-generator
files:
  - secrets/argocd-repo-creds.enc.yaml
  - secrets/rancher-bootstrap.enc.yaml
```

#### 1.4.5 The Secret Bootstrap Problem

There is a chicken-and-egg problem: ArgoCD needs the age private key to decrypt secrets, but ArgoCD itself is deployed by GitOps. The bootstrap sequence must handle this:

```
Phase 1 (Manual/Ansible):
  1. Generate age keypair on operator workstation
  2. Create .sops.yaml with the public key as recipient
  3. Install ArgoCD (Helm or manifests, via bootstrap scripts)
  4. Create the sops-age-key Secret manually:
     kubectl -n argocd create secret generic sops-age-key \
       --from-file=keys.txt=~/.config/sops/age/keys.txt
  5. Mount the secret into the ArgoCD repo-server

Phase 2 (GitOps takes over):
  6. ArgoCD Application pointing at the repo now works
  7. KSOPS decrypts secrets during manifest rendering
  8. All subsequent secret changes go through Git
```

The age private key is the one secret that **cannot** be in Git. It must be:
- Generated on the operator workstation
- Backed up to a secure offline location (Synology, USB drive)
- Injected into the cluster manually during bootstrap
- The `.sops.yaml.example` file in Git documents the expected format without containing the actual key

#### 1.4.6 Secret Rotation

SOPS + age rotation workflow:

```bash
# Re-encrypt all secrets with a new age key (key rotation)
# 1. Generate new age keypair
age-keygen -o new-key.txt

# 2. Update .sops.yaml with the new public key
# 3. Re-encrypt all secrets:
find k8s/ -name '*.enc.yaml' -exec sops updatekeys {} \;

# 4. Commit the re-encrypted files
# 5. Update the sops-age-key Secret in the cluster with the new private key
# 6. ArgoCD auto-syncs, KSOPS uses the new key to decrypt
```

**Rotation frequency guidance:**
- Homelab: Rotate when compromised or annually
- Enterprise: Rotate quarterly or on personnel changes
- The rotation is a re-encryption operation, not a re-generation of the underlying secrets. The actual secret values remain the same unless you choose to change them.

### 1.5 Avoiding Drift: The GitOps Anti-Patterns

#### 1.5.1 Drift Sources

| Drift Source | Example | Prevention |
|-------------|---------|------------|
| **Manual kubectl edits** | `kubectl edit deployment` | ArgoCD self-heal reverts within 3 minutes |
| **Rancher write-back** | Rancher UI modifies a GitOps-managed resource | Restrict Rancher to read-only on ArgoCD-managed namespaces |
| **Helm hooks outside ArgoCD** | Running `helm upgrade` directly | Never run Helm manually on ArgoCD-managed releases |
| **CRD controller side-effects** | A controller adds annotations/labels | Use ArgoCD's `ignoreDifferences` for controller-managed fields |
| **Admission webhook mutations** | A webhook adds sidecars or labels | Include expected mutations in Git manifests, or use `ignoreDifferences` |

#### 1.5.2 The Rancher Write-Path Boundary

This architecture enforces a strict boundary:

```
ArgoCD owns:
  - All resources in k8s/platform/ and k8s/apps/
  - Namespaces: argocd, cert-manager, longhorn-system, gateway-api, observability
  - Application workloads

Rancher owns:
  - cattle-system namespace (its own components)
  - cattle-fleet-system (Fleet agent, if used)
  - Cluster visibility, user RBAC management

Rancher does NOT:
  - Modify resources in ArgoCD-managed namespaces
  - Deploy applications via Fleet into namespaces ArgoCD manages
  - Override Helm values that ArgoCD applies
```

This is enforced by:
1. ArgoCD's `selfHeal: true` — any drift is reverted
2. Rancher RBAC — restrict Rancher's service account to read-only on platform namespaces
3. Convention — the team knows that all changes go through Git

#### 1.5.3 Sync Status States

| Status | Meaning | Action Required |
|--------|---------|-----------------|
| **Synced** | Live state matches desired state | None |
| **OutOfSync** | Diff detected between Git and cluster | Review diff; sync if auto-sync disabled |
| **Unknown** | ArgoCD cannot determine status | Check repo-server connectivity, Git access |
| **Missing** | Resource exists in Git but not in cluster | Sync will create it |
| **Orphaned** | Resource exists in cluster but not in Git | Prune will delete it (if `prune: true`) |

#### 1.5.4 Health Status

| Health | Meaning |
|--------|---------|
| **Healthy** | Resource is operating correctly |
| **Progressing** | Resource is moving toward healthy (Deployment rolling out) |
| **Degraded** | Resource has an error (CrashLoopBackOff, insufficient replicas) |
| **Suspended** | Resource is paused (CronJob, scaled-to-zero) |
| **Missing** | Resource does not exist in the cluster |

### 1.6 Repository Structure for GitOps

The recommended repository layout separates infrastructure automation from cluster-managed resources:

```
# Infrastructure repo (this repo)
iac/
├── constants.yaml                 # Shared constants
├── ansible/                       # Host-level automation (seed layer)
└── tofu/                          # External resources (seed layer)

k8s/
├── bootstrap/                     # Pre-GitOps manual apply (kube-vip, Cilium, etc.)
│   ├── cert-manager/
│   ├── cilium/
│   ├── gateway-api/
│   ├── kube-vip/
│   └── longhorn/
├── platform/                      # ArgoCD-managed platform components
│   ├── argocd/                    # ArgoCD self-manages after bootstrap
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── helm-values.yaml
│   │   └── secrets/
│   │       └── repo-creds.enc.yaml
│   ├── cert-manager/
│   ├── gateway-api/
│   ├── observability/
│   └── rancher/
└── apps/                          # Application workloads
    ├── app-of-apps.yaml           # Root Application that bootstraps all platform apps
    └── ...
```

**Key conventions:**
- `k8s/bootstrap/` — Applied manually once, before ArgoCD exists
- `k8s/platform/` — Managed by ArgoCD after bootstrap handoff
- `k8s/apps/` — Application workloads, also ArgoCD-managed
- Each directory under `platform/` is one ArgoCD Application
- Secrets in `secrets/*.enc.yaml` are SOPS-encrypted

---

## 2. Competitive Landscape Analysis

### 2.1 GitOps Tools

| Criterion | **ArgoCD** | **FluxCD** | **Rancher Fleet** |
|-----------|-----------|-----------|-------------------|
| **Architecture** | Centralized hub (server + controller + repo-server) | Decentralized controllers per cluster | Centralized Fleet Manager + per-cluster agents |
| **CNCF status** | Graduated | Graduated | Not CNCF (SUSE project) |
| **UI** | Built-in web UI with resource tree, diff, logs | No built-in UI; Weave GitOps optional | Integrated in Rancher Dashboard |
| **Manifest rendering** | Helm, Kustomize, plain YAML, Jsonnet, custom plugins | Helm, Kustomize | Helm, Kustomize, plain YAML (all converted to Helm internally) |
| **Multi-cluster** | ApplicationSets with cluster generator | Flux instances per cluster, or Flux Operator | Native multi-cluster (Fleet's primary design goal) |
| **Secret handling** | KSOPS, Vault plugin, ESO | SOPS native integration | Limited (manual secrets or ESO) |
| **Progressive delivery** | ApplicationSet RollingSync; Argo Rollouts integration | Flagger integration | GitRepo-level progressive rollouts |
| **Drift detection** | 3-way diff, server-side diff, self-heal | Drift detection modes (enabled/warn) | Bundle drift correction |
| **Scalability** | ~5,000 apps per instance; sharding for more | Linear per cluster; no central bottleneck | Designed for "up to 1 million clusters" (SUSE claim) |
| **RBAC** | AppProjects with source/destination restrictions | Kubernetes native RBAC | Rancher RBAC integration |
| **Learning curve** | Medium (concepts + UI help) | Medium-High (no UI, Toolkit approach) | Low if already using Rancher |
| **Community size** | ~18k GitHub stars; largest ecosystem | ~6k GitHub stars; strong CNCF backing | Smaller; Rancher-centric |

### 2.2 Pros/Cons Deep Dive

**ArgoCD:**
- ✅ Best-in-class UI for visualizing cluster state, diffs, and sync history
- ✅ ApplicationSets provide powerful multi-cluster and multi-environment templating
- ✅ Mature KSOPS integration for SOPS-encrypted secrets
- ✅ Sync waves and hooks provide fine-grained deployment ordering
- ✅ Server-side diff eliminates false positives from admission webhooks
- ❌ Centralized architecture is a single point of failure (mitigated by HA mode)
- ❌ Redis dependency adds operational complexity
- ❌ Performance degrades above ~5,000 applications without sharding
- ❌ Repo-server is CPU/memory intensive for large repos with many Helm charts

**FluxCD:**
- ✅ Decentralized — no single point of failure; each cluster is self-managing
- ✅ Native SOPS support (no plugin needed)
- ✅ Lightweight resource footprint; ideal for edge
- ✅ OCI artifact support for storing manifests in container registries
- ✅ Flagger integration for canary/blue-green deployments
- ❌ No built-in UI — harder to adopt for teams used to dashboards
- ❌ Multi-cluster management requires external orchestration or Flux Operator
- ❌ Less intuitive debugging without visual resource tree
- ❌ Smaller community; fewer third-party integrations

**Rancher Fleet:**
- ✅ Native Rancher integration — seamless if Rancher is your management plane
- ✅ Designed for massive multi-cluster scale
- ✅ Cluster targeting via labels and groups
- ✅ Helm-based under the hood — everything becomes a Helm release
- ❌ Tied to the Rancher ecosystem
- ❌ Smaller community than ArgoCD/Flux
- ❌ Less mature secret management integration
- ❌ Fleet Agent adds overhead to each downstream cluster

### 2.3 Secret Management Solutions

| Criterion | **SOPS + age** | **Sealed Secrets** | **External Secrets Operator** | **HashiCorp Vault** |
|-----------|---------------|-------------------|------------------------------|-------------------|
| **Model** | Encrypt files in Git | Encrypt CRs in Git; decrypt in-cluster | Fetch from external backend at runtime | Centralized secret store with API |
| **Git-native** | ✅ Yes (encrypted values in Git) | ✅ Yes (SealedSecret CRs in Git) | ❌ No (secrets live outside Git) | ❌ No |
| **Operator required** | ❌ No (Kustomize plugin) | ✅ Yes (kubeseal controller) | ✅ Yes (ESO controller) | ✅ Yes (Vault Agent/CSI) |
| **Key management** | age keypair (operator manages) | RSA keypair (controller manages) | Backend-specific (IAM, tokens) | Vault's own auth backends |
| **Portability** | ✅ Decrypt anywhere with the age key | ❌ Tied to one cluster's sealing key | ❌ Tied to external backend | ❌ Tied to Vault instance |
| **Rotation** | Re-encrypt files with `sops updatekeys` | Re-seal with new cert | Backend handles rotation | Vault dynamic secrets |
| **Complexity** | Low | Low-Medium | Medium-High | High |
| **Best for** | Small teams, homelab, GitOps-native | Single-cluster, simple secrets | Enterprise, cloud-native, multi-backend | Enterprise, dynamic secrets, PKI |
| **Disaster recovery** | Git + age key = full restore | Backup sealing key separately | Restore external backend first | Restore Vault first |

---

## 3. Under the Hood

### 3.1 How ArgoCD Renders Manifests

The repo-server is the computational engine of ArgoCD. When it needs to render manifests for an Application, it:

```
1. Acquires a semaphore slot (concurrency limited per repo)
2. Clones or fetches the Git repo (cached in a shared volume)
3. Checks out the target revision (branch, tag, or commit SHA)
4. Detects the manifest source type:
   - Helm chart: looks for Chart.yaml
   - Kustomize: looks for kustomization.yaml
   - Plain directory: everything else
5. Renders manifests:
   Helm:
     → helm dependency build
     → helm template --values <values-files> --set <overrides>
   Kustomize:
     → kustomize build --enable-alpha-plugins (if KSOPS is used)
     → KSOPS exec plugin runs: sops --decrypt <encrypted-file>
   Plain:
     → Concatenates all YAML files in the directory
6. Parses rendered YAML into structured Kubernetes objects
7. Caches the result in Redis (keyed by repo + revision + path + values hash)
8. Returns the manifest set to the Application Controller
```

**Performance implications:**
- The repo-server maintains a Git repo cache. The first clone is slow; subsequent fetches are fast
- Helm rendering can be CPU-intensive for complex charts with many templates
- KSOPS adds latency for each encrypted file (age decryption)
- Redis caching means repeated reconciliation of unchanged Applications is nearly free

### 3.2 How SOPS Encrypts Structured Data

SOPS implements **envelope encryption** — a two-layer system:

```
Layer 1: Data Encryption
  ┌─────────────────────────────────┐
  │ For each value in YAML/JSON:    │
  │   plaintext_value               │
  │     → AES-256-GCM encrypt       │
  │     → with random data key      │
  │     → produces ciphertext       │
  │     → stored as ENC[...] block  │
  └─────────────────────────────────┘

Layer 2: Key Encryption
  ┌─────────────────────────────────┐
  │ The random data key:            │
  │   → encrypted with age          │
  │     (X25519 + ChaCha20-Poly1305)│
  │   → encrypted for each          │
  │     recipient in .sops.yaml     │
  │   → stored in sops metadata     │
  └─────────────────────────────────┘
```

**Why envelope encryption?**
1. Performance: AES-256-GCM is fast for bulk data; asymmetric encryption is slow
2. Multiple recipients: The data key can be encrypted for multiple age keys without re-encrypting every value
3. Key rotation: To rotate the master key, only the data key needs re-wrapping — individual values are untouched

**`.sops.yaml` creation rules:**

```yaml
# .sops.yaml — Encryption rules
# Specifies which files get encrypted with which keys
creation_rules:
  # All encrypted files under k8s/secrets/
  - path_regex: k8s/.*/secrets/.*\.enc\.yaml$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
    # Can add multiple recipients for team access:
    # age: >-
    #   age1key1...,age1key2...

  # Ansible vault secrets (if any)
  - path_regex: iac/ansible/.*\.enc\.yml$
    age: >-
      age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
```

### 3.3 The Kubernetes Watch Mechanism Behind GitOps

ArgoCD's Application Controller uses the Kubernetes watch API extensively. Understanding how watches work is essential for debugging GitOps reconciliation issues.

```
Application Controller:
  → Opens a WATCH on Application CRDs in the argocd namespace
  → Opens watches on ALL resource types that Applications manage
  → Watch connections are long-lived HTTP/2 streams
  → The API server's watch cache delivers events:
      ADDED, MODIFIED, DELETED
  → Controller maintains an in-memory resource graph
  → When an event arrives:
      → Update the resource graph
      → Re-compute sync/health status
      → If OutOfSync + auto-sync → trigger sync
```

**Resource tracking methods:**

| Method | Mechanism | Pros | Cons |
|--------|-----------|------|------|
| **Label** (default) | `app.kubernetes.io/instance` label | Standard; works everywhere | Label collisions possible |
| **Annotation** | `argocd.argoproj.io/tracking-id` | No label pollution | ArgoCD-specific |
| **Annotation+Label** | Both | Maximum compatibility | Verbose |

### 3.4 Rancher Agent-to-Server Communication

When a cluster is registered in Rancher, the Rancher Agent establishes a **WebSocket tunnel** to the Rancher server:

```
Rancher Agent (downstream cluster)
  → Opens WebSocket to Rancher Server
  → Tunnel carries:
      - kubectl proxy traffic (Rancher UI → cluster API)
      - Cluster status reports
      - Event streams
  → Direction: Agent initiates outbound only
  → No inbound firewall rules needed on downstream cluster
```

This is a pull-based architecture for cluster management — similar to GitOps principles. The downstream cluster reaches out to Rancher, not the other way around.

---

## 4. Cloud vs. On-Prem Context

### 4.1 GitOps Across Environments

| Aspect | **On-Prem (RKE2 + ArgoCD)** | **AWS EKS** | **GCP GKE** | **Azure AKS** |
|--------|---------------------------|-------------|-------------|---------------|
| **ArgoCD deployment** | Self-managed; full control over Helm values and resources | Self-managed on EKS; or AWS CodePipeline as alternative | Self-managed; or Google Cloud Deploy as alternative | Self-managed; or Azure GitOps (Flux-based) as alternative |
| **Git repo hosting** | Self-hosted Gitea/GitLab or cloud (GitHub/GitLab SaaS) | CodeCommit or GitHub/GitLab SaaS | Cloud Source Repos or GitHub/GitLab SaaS | Azure Repos or GitHub/GitLab SaaS |
| **Secret backend** | SOPS + age (file-based) | AWS Secrets Manager + ESO, or SOPS + KMS | GCP Secret Manager + ESO, or SOPS + KMS | Azure Key Vault + ESO, or SOPS + KMS |
| **Secret encryption** | age keypair managed by operator | AWS KMS (SOPS can use KMS instead of age) | GCP KMS (SOPS can use KMS) | Azure Key Vault (SOPS can use Key Vault) |
| **Multi-cluster** | ArgoCD ApplicationSets | EKS Anywhere + ArgoCD; or Fleet for Rancher users | GKE Fleet (built-in); or ArgoCD | AKS Fleet Manager; or ArgoCD |
| **Identity for Git** | SSH keys or token (manual) | IAM role for CodeCommit; or deploy keys | Workload Identity for Source Repos; or deploy keys | Azure AD for Repos; or deploy keys |
| **Network to Git** | Direct (if Git is on the internet) or VPN | VPC endpoint for CodeCommit | VPC-SC for Source Repos | Private endpoint for Repos |

### 4.2 Cloud-Native Alternatives to ArgoCD

Each cloud provider offers a managed GitOps or CD solution:

**AWS:**
- **AWS CodePipeline + CodeBuild:** Push-based CI/CD; not GitOps (no reconciliation loop)
- **EKS Blueprints with ArgoCD:** AWS-curated ArgoCD deployment patterns
- **AWS Proton:** Infrastructure templates; different abstraction layer

**GCP:**
- **Google Cloud Deploy:** Push-based CD for GKE; not GitOps-native
- **GKE Config Sync:** Flux-based GitOps built into GKE; automatic reconciliation
- **Anthos Config Management:** Enterprise multi-cluster config sync

**Azure:**
- **Azure GitOps (AKS):** Built on FluxCD; native AKS integration
- **Azure DevOps Pipelines:** Push-based CI/CD
- **Azure Arc-enabled Kubernetes:** GitOps for hybrid/multi-cloud via Flux

### 4.3 SOPS Key Management: Cloud vs On-Prem

| Environment | Key Backend | How SOPS Uses It |
|-------------|------------|------------------|
| **On-Prem** | age keypair (file-based) | `sops --age age1...` — simple, portable |
| **AWS** | AWS KMS | `sops --kms arn:aws:kms:...` — IAM-controlled, audit logged |
| **GCP** | Cloud KMS | `sops --gcp-kms projects/.../keys/...` — IAM-controlled |
| **Azure** | Azure Key Vault | `sops --azure-kv https://vault.vault.azure.net/keys/...` |
| **Multi-env** | Multiple backends | `.sops.yaml` can specify different keys per path regex |

**On-prem advantage:** The age private key is completely under your control. No cloud IAM policies, no API rate limits, no network dependencies for decryption.

**On-prem disadvantage:** You are responsible for key backup, rotation, and access control. There is no cloud audit trail of key usage.

### 4.4 Rancher Multi-Cloud

Rancher's value proposition grows in multi-cloud scenarios:

```
Rancher Management Cluster (on-prem RKE2)
  ├── Downstream: lab-cluster (on-prem RKE2)
  ├── Downstream: dev-eks (AWS EKS, imported)
  ├── Downstream: staging-gke (GCP GKE, imported)
  └── Downstream: prod-aks (Azure AKS, imported)
```

Each downstream cluster runs a Rancher Agent that tunnels back to the management cluster. This gives unified visibility, RBAC, and (optionally) Fleet GitOps across all environments. ArgoCD instances in each cluster handle the local delivery.

---

## 5. Follow-Along Exercise: ArgoCD + SOPS + Rancher on RKE2

### 5.1 Architecture Overview

This exercise builds on Chapter 1's cluster and adds:
- ArgoCD deployed via Helm (bootstrap phase)
- SOPS + age for encrypted secrets
- KSOPS integration for ArgoCD secret decryption
- Platform Application definitions for ArgoCD to manage
- Rancher deployed behind the Gateway (as an ArgoCD Application)

### 5.2 Prerequisites

- Working 3-node RKE2 cluster from Chapter 1
- CNI installed (Cilium — covered in Chapter 4; for this exercise, any working CNI)
- `kubectl` access via the VIP
- `age` and `sops` installed on operator workstation
- `helm` installed on operator workstation

### 5.3 File Structure

```
platform-expert-kubernetes-at-scale/src/chapter_02/
├── constants.yaml → ../chapter_01/constants.yaml (symlink — same source of truth)
├── ansible/
│   ├── playbooks/
│   │   ├── 01-sops-setup.yml         # Generate age key, create .sops.yaml
│   │   └── 02-argocd-bootstrap.yml   # Install ArgoCD + inject age key
│   └── roles/
│       ├── sops_setup/
│       │   ├── tasks/main.yml
│       │   └── templates/
│       │       └── sops.yaml.j2
│       └── argocd_install/
│           └── tasks/main.yml
├── k8s/
│   ├── argocd/
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   ├── helm-values.yaml
│   │   └── appproject-platform.yaml
│   ├── platform-apps/
│   │   ├── app-of-apps.yaml          # Root Application
│   │   ├── argocd-app.yaml           # ArgoCD self-management
│   │   └── rancher-app.yaml          # Rancher Application
│   └── secrets/
│       ├── kustomization.yaml
│       ├── secret-generator.yaml     # KSOPS generator
│       └── argocd-repo-creds.enc.yaml.example
└── tofu/
    └── main.tf                       # (Optional) GitHub repo webhook for ArgoCD
```

### 5.4 Step-by-Step Instructions

#### Step 1: Generate the age Keypair

Run the SOPS setup playbook to generate the age key and `.sops.yaml`:

```bash
cd platform-expert-kubernetes-at-scale/src/chapter_02/

# Or manually:
age-keygen -o age-key.txt
# Output:
# # created: 2026-03-28T12:00:00Z
# # public key: age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p
# AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ

# Store the private key securely
mkdir -p ~/.config/sops/age/
cp age-key.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Back up to Synology (CRITICAL — this key is your disaster recovery lifeline)
# scp age-key.txt synology:/volume1/backups/sops/age-key.txt
```

→ See: `src/chapter_02/ansible/playbooks/01-sops-setup.yml`

#### Step 2: Create an Encrypted Secret

```bash
# Create a plaintext secret
cat <<EOF > /tmp/argocd-repo-creds.yaml
apiVersion: v1
kind: Secret
metadata:
  name: repo-credentials
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
type: Opaque
stringData:
  type: git
  url: https://github.com/your-org/your-repo.git
  password: ghp_your_github_token_here
  username: git
EOF

# Encrypt with SOPS
sops --encrypt --age age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p \
  /tmp/argocd-repo-creds.yaml > k8s/secrets/argocd-repo-creds.enc.yaml

# Verify: keys are visible, values are encrypted
cat k8s/secrets/argocd-repo-creds.enc.yaml

# Clean up plaintext
rm /tmp/argocd-repo-creds.yaml
```

#### Step 3: Bootstrap ArgoCD

```bash
ansible-playbook -i ../chapter_01/ansible/inventory.ini \
  ansible/playbooks/02-argocd-bootstrap.yml
```

This playbook:
1. Creates the `argocd` namespace
2. Installs ArgoCD via Helm with custom values
3. Injects the age private key as a Kubernetes Secret
4. Patches the repo-server to mount the age key and include KSOPS

→ See: `src/chapter_02/ansible/playbooks/02-argocd-bootstrap.yml`

#### Step 4: Access ArgoCD UI

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Port-forward to access the UI (until Gateway is configured)
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Open: https://localhost:8080
# Login: admin / <password from above>
```

#### Step 5: Deploy the App of Apps

The root Application bootstraps all platform Applications:

```bash
kubectl apply -f k8s/platform-apps/app-of-apps.yaml
```

→ See: `src/chapter_02/k8s/platform-apps/app-of-apps.yaml`

#### Step 6: Verify GitOps Reconciliation

```bash
# Check Application sync status
kubectl -n argocd get applications

# Watch for drift correction
# Make a manual change:
kubectl -n argocd annotate svc argocd-server manual-change=true

# Wait up to 3 minutes (or check ArgoCD UI)
# ArgoCD self-heal will remove the annotation

# Verify in ArgoCD CLI
kubectl -n argocd exec -it deploy/argocd-server -- argocd app list
```

#### Step 7: (Later) Deploy Rancher

Rancher is deployed as an ArgoCD Application after the Gateway is configured (Chapter 4):

→ See: `src/chapter_02/k8s/platform-apps/rancher-app.yaml`

---

## 6. Interview Questions

### Staff/Senior-Level GitOps, Secret Management & Fleet Interview Questions

**Q1: Explain the fundamental difference between push-based CI/CD and pull-based GitOps. What security implications does this have?**

*Expected answer:* Push-based CI/CD has an external system (Jenkins, GitHub Actions) that authenticates to the cluster and runs `kubectl apply`. This requires the CI system to hold cluster credentials — a high-value target. If the CI system is compromised, the attacker has direct write access to the cluster. Pull-based GitOps inverts this: the in-cluster agent (ArgoCD) pulls from Git. The cluster needs read access to Git (a deploy key), but Git doesn't need access to the cluster. The attack surface is smaller: compromising the Git repo allows changing desired state (visible in Git history), but doesn't provide direct cluster API access. Additionally, every change in Git is auditable, whereas push-based `kubectl apply` from a CI runner may not leave a clear audit trail.

---

**Q2: Describe ArgoCD's 3-way diff mechanism. Why is a 3-way diff necessary instead of a simple 2-way comparison between Git and the cluster?**

*Expected answer:* A 2-way diff (Git vs. live) would flag every field that exists in the live state but not in Git — including fields added by controllers (like `status`, `metadata.managedFields`, defaulted values). This would create constant false-positive OutOfSync states. The 3-way diff compares: (1) desired state from Git, (2) live state from the cluster, (3) the last-applied configuration (stored as an annotation or via server-side apply tracking). The 3-way diff can distinguish between: (a) a field that was explicitly removed from Git (present in last-applied, absent in desired → should be removed), (b) a field that was never in Git but was added by a controller (absent in last-applied, present in live → should be ignored), and (c) a field that was changed in Git (different between desired and last-applied → should be updated). Server-side diff (v2.5+) improves on this by using the API server's dry-run, which correctly handles defaulting and admission webhook mutations.

---

**Q3: You have an ArgoCD Application that shows `OutOfSync` constantly even though you haven't changed anything in Git. How do you diagnose and fix this?**

*Expected answer:* Common causes: (1) A mutating admission webhook is modifying resources after ArgoCD applies them (injecting sidecars, adding labels). Fix: add the mutated fields to `spec.ignoreDifferences` in the Application. (2) A controller is setting a field that ArgoCD doesn't manage (e.g., `status.replicas` on an HPA). Fix: `ignoreDifferences` for that specific field. (3) Helm rendering includes timestamps or random values that change on every render. Fix: use deterministic Helm values; avoid `{{ now }}` in templates. (4) Default values differ between the API server version and Helm chart expectations. Fix: switch to server-side diff (`ServerSideApply=true` sync option). Diagnosis: (a) Click the Application in ArgoCD UI, examine the diff for each OutOfSync resource. (b) Check `argocd app diff <app-name> --local <path>` to see the exact fields. (c) Look at the `managedFields` on the live object to see which controller is modifying it.

---

**Q4: Explain how SOPS envelope encryption works. Why doesn't SOPS encrypt the entire file?**

*Expected answer:* SOPS uses envelope encryption: it generates a random data key, encrypts each value individually with AES-256-GCM using that data key, then encrypts the data key itself with the master key (age, KMS, etc.). SOPS doesn't encrypt the entire file because: (1) Meaningful Git diffs — you can see which keys changed even though values are encrypted. A reviewer can see "the password field was modified" without seeing the actual password. (2) Merge conflict resolution — since YAML structure and keys are visible, Git can merge changes to different keys without conflicts. Full-file encryption makes merges impossible. (3) Selective encryption — SOPS can be configured to encrypt only specific keys (e.g., `stringData` but not `metadata`), leaving non-sensitive structure readable. (4) Multiple recipients — the data key can be wrapped for multiple age/KMS keys without re-encrypting every value. This is efficient for team rotation.

---

**Q5: Describe the chicken-and-egg problem in GitOps secret bootstrapping. How does this architecture solve it?**

*Expected answer:* ArgoCD needs the SOPS age private key to decrypt secrets from Git. But the age key itself is a secret — and you can't store it encrypted in Git because you'd need the key to decrypt it. This is a circular dependency. The solution is a two-phase bootstrap: (1) Manual phase: generate the age keypair on the operator workstation, install ArgoCD via Helm, and manually create a Kubernetes Secret containing the age private key. Mount this secret into the ArgoCD repo-server. (2) GitOps phase: once ArgoCD has the key, it can decrypt all other secrets from Git via KSOPS. All subsequent secrets go through Git. The age private key is the single bootstrap secret that must be managed outside Git. It must be backed up securely (offline storage, Synology, etc.) because losing it means losing the ability to decrypt all SOPS-encrypted secrets. The `.sops.yaml.example` file in Git documents the expected configuration without containing the actual key.

---

**Q6: What happens if someone runs `kubectl edit` on a resource managed by ArgoCD with `selfHeal: true`? Walk through the exact sequence of events.**

*Expected answer:* (1) User modifies the resource via `kubectl edit`. (2) The Kubernetes API server persists the change and increments the resourceVersion. (3) ArgoCD's Application Controller receives a WATCH event for the modified resource. (4) The controller re-computes the diff: desired state (Git) vs. live state (modified). (5) The resource is now OutOfSync because the live state differs from Git. (6) Because `selfHeal: true`, the controller immediately triggers a sync for that resource. (7) ArgoCD applies the desired state from Git, overwriting the manual change. (8) The resource returns to Synced + Healthy. (9) The ArgoCD event log records both the drift detection and the self-heal sync. This typically happens within seconds of the manual edit if the watch event is processed quickly, or up to 3 minutes (the default reconciliation interval) in the worst case.

---

**Q7: Explain the difference between ArgoCD sync waves and ApplicationSet progressive syncs. When would you use each?**

*Expected answer:* Sync waves operate within a single Application — they order resources inside that Application. Example: wave -1 creates the Namespace, wave 0 deploys the CRDs, wave 1 deploys the operator, wave 2 creates the custom resources. Use sync waves when resources within one Application have dependencies. Progressive syncs operate across multiple Applications generated by an ApplicationSet — they order Application updates in stages. Example: stage 1 syncs the staging cluster, stage 2 syncs 25% of production clusters, stage 3 syncs the remaining 75%. Use progressive syncs for canary-style rollouts across environments or clusters. They solve fundamentally different problems: intra-Application ordering vs. inter-Application rollout strategy. You often use both together — sync waves within each Application for correct resource ordering, and progressive syncs across ApplicationSets for safe multi-environment deployments.

---

**Q8: How does ArgoCD's repo-server cache work? What are the implications for manifest rendering performance and correctness?**

*Expected answer:* The repo-server maintains two levels of caching: (1) Git repo cache — cloned repos are stored on disk and fetched incrementally. This avoids full clones on every reconciliation cycle. (2) Manifest cache — rendered manifests are cached in Redis, keyed by repo URL + revision + path + values hash. If the key matches, the cached manifest is returned without re-rendering. Performance implications: first render is slow (clone + render), subsequent renders with same inputs are fast (Redis hit). Correctness implications: if a Helm chart depends on external resources (like a dependency from a Helm repo that's been updated), the cache may serve stale results. Fix: use `argocd app get <app> --hard-refresh` or configure cache expiration. The cache can also mask rendering errors — a broken chart that was previously cached may appear to work until the cache expires. Clear the cache with `argocd cache clear` when debugging.

---

**Q9: Design a secret rotation strategy for a production cluster using SOPS + age. Cover both the master key rotation and individual secret value rotation.**

*Expected answer:* **Master key rotation** (the age key itself): (1) Generate a new age keypair. (2) Update `.sops.yaml` to include both old and new public keys as recipients. (3) Run `sops updatekeys` on every encrypted file — this re-wraps the data key for both recipients. (4) Commit the re-encrypted files to Git. (5) Update the SOPS age key Secret in the cluster with the new private key. (6) ArgoCD re-syncs and uses the new key. (7) After confirming everything works, remove the old public key from `.sops.yaml` and run `sops updatekeys` again to remove the old key's access. **Individual secret rotation** (e.g., a database password): (1) `sops edit k8s/secrets/db-creds.enc.yaml` — this decrypts in-memory, opens your editor, re-encrypts on save. (2) Change the password value. (3) Commit to Git. (4) ArgoCD syncs the new Secret. (5) Pods referencing the Secret may need a restart (Secrets are not live-reloaded by default; use Reloader or similar). Important: secret rotation and key rotation are different operations. Key rotation re-wraps the same data; secret rotation changes the actual secret values.

---

**Q10: You're debugging an ArgoCD Application that shows `Healthy` but the application is not working. What are the possible causes and how do you investigate?**

*Expected answer:* ArgoCD's health assessment is based on resource-level checks, not application-level checks. Possible causes: (1) ArgoCD considers a Deployment `Healthy` when all replicas are running and ready — but the readiness probe may be too permissive (e.g., checking `/healthz` which returns 200 even when the app can't reach its database). (2) The application depends on external resources (database, API) that ArgoCD doesn't track. (3) ConfigMap or Secret values are incorrect but structurally valid. (4) Network policies block traffic but the pods themselves are healthy. (5) The Service selector doesn't match the Pod labels (no traffic reaches the pods, but Pods are Running). Investigation: (a) Check Pod logs: `kubectl logs -n <ns> <pod>`. (b) Check events: `kubectl get events -n <ns>`. (c) Verify endpoints: `kubectl get endpoints -n <ns> <svc>`. (d) Test connectivity: `kubectl exec` into a debug pod and curl the service. (e) Add custom health checks to ArgoCD for the resource type using Lua scripts.

---

**Q11: Explain the Rancher Agent communication model. Why does the Agent initiate the connection rather than Rancher Server connecting to downstream clusters?**

*Expected answer:* The Rancher Agent establishes an outbound WebSocket tunnel to the Rancher Server. This design choice is driven by network topology: (1) Downstream clusters may be behind NAT, firewalls, or in private networks. Requiring inbound connections from Rancher Server to each cluster would require complex firewall rules. (2) The outbound-only model means no inbound ports need to be opened on downstream clusters — a significant security advantage. (3) The WebSocket tunnel carries bidirectional traffic (kubectl proxy, event streams) over a single outbound connection. (4) If the tunnel drops, the Agent reconnects automatically. (5) This mirrors the GitOps pull model — the downstream cluster reaches out to the management plane, not the reverse. The trade-off: the Agent must be able to resolve and reach the Rancher Server URL. In air-gapped environments, this requires internal DNS or direct IP configuration.

---

**Q12: What is the App of Apps pattern in ArgoCD? What problem does it solve and what are its limitations compared to ApplicationSets?**

*Expected answer:* App of Apps is a pattern where a single root Application points to a Git directory containing other Application manifests. When ArgoCD syncs the root Application, it creates the child Applications, which then sync their own sources. It solves the bootstrap problem: you apply one Application, and the entire platform bootstraps. Limitations vs. ApplicationSets: (1) App of Apps requires manually writing each child Application manifest — no templating. (2) Adding a new Application requires editing the root directory. (3) No dynamic generation based on cluster labels, Git branches, or other generators. (4) No progressive sync support — all child Applications sync simultaneously. (5) No matrix or merge generators for complex multi-dimension deployments. ApplicationSets address all of these by dynamically generating Applications from templates and generators. However, App of Apps is simpler to understand and debug, and many teams use a hybrid: App of Apps as the root, with ApplicationSets underneath for dynamic portions.

---

**Q13: How does ArgoCD handle CRDs and the resources that depend on them? What happens if a CRD and its CR are in the same Application?**

*Expected answer:* ArgoCD syncs resources in a specific order within a sync wave: Namespaces first, then CRDs, then other resources. If a CRD and its custom resources are in the same Application at the same sync wave, ArgoCD will apply the CRD first (due to its built-in ordering), wait for it to be established, then apply the CRs. However, if the CRD takes time to become ready (the API server needs to update its discovery cache), the CR apply may fail with "no matches for kind X." Solutions: (1) Use sync waves — put the CRD at wave -1 and the CR at wave 0 or later. (2) Use `Replace=true` sync option to force replacement if apply fails. (3) Use server-side apply which handles missing types more gracefully. (4) Split CRDs and CRs into separate Applications with an explicit dependency. Best practice for this architecture: install CRDs in the bootstrap phase (before ArgoCD exists), then manage CRs via ArgoCD Applications. This avoids the CRD-CR ordering problem entirely.

---

**Q14: Explain the difference between `prune: true` and `selfHeal: true` in ArgoCD's automated sync policy. Give a scenario where you'd want one but not the other.**

*Expected answer:* `prune: true` means: if a resource exists in the cluster but has been removed from Git, ArgoCD will delete it during sync. `selfHeal: true` means: if a resource in the cluster is manually modified (differs from Git), ArgoCD will revert the modification. Scenario for prune without selfHeal: A staging environment where you want ArgoCD to clean up removed resources automatically, but operators need to temporarily override values (like replica count or resource limits) for debugging without ArgoCD reverting them immediately. Scenario for selfHeal without prune: A production environment where manual drift should be corrected immediately, but you never want ArgoCD to automatically delete resources that were removed from Git — deletion should require explicit human action (an ArgoCD sync with prune confirmation). The safest production configuration is `prune: false, selfHeal: true` — drift is corrected, but resources are never automatically deleted.

---

**Q15: How would you design ArgoCD Projects for a multi-team Kubernetes platform? Consider security, autonomy, and operational boundaries.**

*Expected answer:* Design Projects around trust boundaries, not team organizational charts: (1) `platform` Project — owned by the platform team. Can deploy to any namespace, create cluster-scoped resources (CRDs, ClusterRoles, namespaces). Source repos limited to the platform infrastructure repo. (2) `team-<name>` Projects — one per application team. Restricted to specific namespaces (`team-<name>-*`). Cannot create cluster-scoped resources. Source repos limited to team's application repos. Cannot deploy to `kube-system`, `argocd`, or other platform namespaces. (3) `security` Project — for security tools (Falco, OPA). Can deploy to security namespaces, can create cluster-scoped admission policies. RBAC: map ArgoCD Project roles to team identity providers via OIDC groups. Each team manages their Applications within their Project's boundaries. The platform team manages the Projects themselves. This enforces least-privilege: a compromised team repo can only affect that team's namespaces.

---

**Q16: What happens to the cluster if ArgoCD goes down? How do you recover?**

*Expected answer:* If ArgoCD goes down: (1) All existing workloads continue running — ArgoCD is not in the data plane. (2) No new syncs occur — Git changes are not applied. (3) Drift is not detected or corrected — manual changes persist. (4) New Applications are not created. (5) No health monitoring or status updates. The cluster is in the same "brain-dead but alive" state as when the control plane goes down, but only for the GitOps layer. Recovery: (a) If ArgoCD pods crashed, Kubernetes will restart them (they're Deployments with replicas). (b) If the ArgoCD namespace is deleted, you must re-bootstrap ArgoCD (Helm install or manifest apply) and re-inject the SOPS age key Secret. Applications will be recreated from their CRDs in etcd. (c) If etcd is lost, you need a full cluster restore — ArgoCD Applications are Kubernetes CRDs stored in etcd. (d) For disaster recovery of a completely lost cluster: rebuild the cluster, install ArgoCD, point it at Git, inject the age key, and ArgoCD reconverges the entire platform from Git. This is the ultimate value of GitOps: Git is the disaster recovery plan.

---

**Q17: Explain how ArgoCD's notification system works. Design an alerting strategy for a production platform.**

*Expected answer:* ArgoCD Notifications controller watches Application CRDs and sends notifications based on triggers (sync succeeded, sync failed, health degraded). It supports templates and destinations (Slack, webhook, email, Grafana, custom). Strategy: (1) **Sync failures → Slack #platform-alerts** with high urgency. Include Application name, error message, and Git commit. (2) **Health degradation → PagerDuty webhook** for production Applications; Slack for staging. (3) **Successful syncs → Slack #deployments** as informational (low noise, audit trail). (4) **OutOfSync > 15 minutes → Slack warning** — something may be preventing sync. (5) **New Application created → Slack #platform-alerts** — unexpected Applications may indicate unauthorized access. Configure per-Application notification overrides using annotations. Platform team Applications get PagerDuty integration; application team Applications get team-specific Slack channels. Use ArgoCD's built-in `on-sync-succeeded`, `on-sync-failed`, `on-health-degraded` triggers. Avoid alerting on every reconciliation cycle — alert on state transitions only.

---

**Q18: Compare `server-side apply` vs `client-side apply` in the context of ArgoCD. When should you use each?**

*Expected answer:* Client-side apply (default): ArgoCD sends a `kubectl apply` which uses the `last-applied-configuration` annotation for 3-way merge. Problems: (1) Large objects may exceed annotation size limits. (2) Conflicts with other controllers that also set `last-applied-configuration`. (3) Doesn't handle field ownership granularity. Server-side apply: ArgoCD sends a dry-run request to the API server, which uses its own field management tracking (managedFields) to compute the diff. Advantages: (1) No annotation size limits. (2) Field-level ownership tracking — ArgoCD owns the fields it sets, controllers own the fields they set. (3) More accurate diff — the API server handles defaulting and admission. (4) No false-positive OutOfSync for controller-managed fields. Use server-side apply when: CRDs with large specs, resources managed by multiple controllers, or when experiencing constant OutOfSync due to admission webhooks. Use client-side apply when: compatibility is needed with older clusters (pre-1.22), or when server-side apply causes unexpected field ownership conflicts.

---

**Q19: How would you implement a preview environment workflow with ArgoCD ApplicationSets?**

*Expected answer:* Use the Pull Request generator: (1) Configure an ApplicationSet with the PR generator pointing at your application repo. (2) For each open PR, the generator creates a temporary Application deployed to a namespace like `preview-pr-<number>`. (3) The Application sources the PR branch for manifests. (4) Values overrides set the ingress hostname to `pr-<number>.preview.lab.home.arpa`. (5) When the PR is merged or closed, the generator removes the Application, and ArgoCD deletes the namespace and all resources (with prune enabled). Implementation details: (a) Use `requeueAfterSeconds: 30` to poll for new PRs. (b) Add label filters to only generate previews for PRs with a specific label (e.g., `preview`). (c) Use `goTemplate: true` for complex templating. (d) Set resource quotas on preview namespaces to prevent abuse. (e) Add TTL annotations so stale preview environments are cleaned up even if the generator misses a PR close event. This replaces heavyweight preview environment solutions and keeps everything declarative.

---

**Q20: What is the risk of using `--force` with ArgoCD sync? When is it justified?**

*Expected answer:* `--force` deletes and recreates resources instead of patching them. Risks: (1) Downtime — the resource is deleted before the new version is created. For Deployments, this means all pods are terminated and restarted. (2) Loss of status — controller-set fields (like observed generation, conditions) are reset. (3) PVC recreation — if a StatefulSet is force-synced, its PVCs might be deleted (depending on reclaim policy), causing data loss. (4) Service VIP change — deleting and recreating a LoadBalancer Service may allocate a new IP. Justified scenarios: (1) Immutable field changes — some fields (like a Job's `spec.template` or a Service's `clusterIP` type change) cannot be patched. Force-sync is the only option. (2) Stuck resources — a resource in a bad state that won't accept patches (webhook blocking updates). (3) Schema changes — a CRD version change that requires resource recreation. Best practice: never enable force globally. Use `argocd app sync <app> --resource <kind>:<name> --force` to force-sync individual resources when needed.

---

**Q21: Explain the KSOPS decryption pipeline in detail. What happens if the age key in the cluster is wrong or missing?**

*Expected answer:* Pipeline: (1) ArgoCD repo-server runs `kustomize build` on the Application path. (2) Kustomize encounters a generator reference to a KSOPS generator YAML. (3) KSOPS exec plugin is invoked. (4) KSOPS reads each file listed in the generator's `files` list. (5) KSOPS calls `sops --decrypt` on each file. (6) SOPS reads the `sops` metadata block in the encrypted file to find the age recipient. (7) SOPS looks for the age private key in `$SOPS_AGE_KEY_FILE` (or default location). (8) SOPS uses the age private key to decrypt the data key in the metadata. (9) SOPS uses the data key to AES-256-GCM decrypt each value. (10) Decrypted YAML is returned to Kustomize as a generated resource. If the key is wrong: SOPS will fail to decrypt the data key wrapping and return an error. KSOPS propagates this error. Kustomize build fails. ArgoCD marks the Application as `ComparisonError`. The Application shows an error message like "failed to decrypt file." If the key is missing: SOPS can't find the key file and errors immediately. Same Application error state. In both cases, the Application remains at its last successfully synced state — no partial or broken manifests are applied.

---

**Q22: How do you prevent Rancher from becoming a second write path for resources managed by ArgoCD?**

*Expected answer:* Multiple enforcement layers: (1) **ArgoCD `selfHeal: true`**: Any change Rancher makes to ArgoCD-managed resources is reverted within seconds to minutes. (2) **Rancher RBAC**: Create a custom Rancher GlobalRole or ClusterRole that has read-only access to ArgoCD-managed namespaces. Bind this to all non-admin users. (3) **Kubernetes RBAC**: Create a ValidatingAdmissionPolicy or webhook that rejects mutations to resources with the `app.kubernetes.io/managed-by: argocd` label from Rancher's service account. (4) **Convention**: Document clearly that all changes go through Git. Rancher is for viewing, not editing. (5) **Rancher Projects**: Do not include ArgoCD-managed namespaces in Rancher Projects where users have write access. (6) **ArgoCD AppProjects**: Configure AppProjects to reject sync from Rancher's IP/user if possible. The most pragmatic approach for a single-operator homelab is layer 1 (selfHeal) plus layer 4 (convention). Layers 2-3 matter when teams grow.

---

**Q23: Describe how you would perform a disaster recovery of the entire platform using only Git and the age private key.**

*Expected answer:* Assuming total cluster loss: (1) Provision new hardware/VMs with Ubuntu 24.04. (2) Run Ansible host-prep and RKE2 install playbooks from Git (Chapter 1). (3) Bootstrap the 3-node RKE2 cluster. (4) Install kube-vip (static pod manifest from Git). (5) Install CNI (Cilium Helm values from Git). (6) Install ArgoCD via Helm (values from Git). (7) Inject the age private key: `kubectl create secret generic sops-age-key -n argocd --from-file=keys.txt=<backup-key>`. (8) Apply the App of Apps: `kubectl apply -f k8s/platform-apps/app-of-apps.yaml`. (9) ArgoCD begins reconciling: decrypts secrets via KSOPS, deploys cert-manager, Gateway, Rancher, observability, and all applications. (10) Restore stateful data from backups (etcd snapshots for cluster state, Longhorn backups for PVCs). RPO is determined by backup frequency. RTO depends on: hardware provisioning time + Ansible run time + ArgoCD convergence time + data restore time. For a 3-node homelab, expect 1-2 hours from bare metal to fully converged platform. The key insight: Git + age key = complete platform definition. Backups provide data, not configuration.

---

**Q24: What are the security risks of the ArgoCD repo-server, and how do you harden it?**

*Expected answer:* The repo-server is the highest-risk ArgoCD component because it: (1) Clones external Git repos — potentially untrusted code. (2) Renders Helm templates — Helm's `tpl` function can execute arbitrary Go templates. (3) Runs Kustomize plugins — exec plugins like KSOPS run arbitrary binaries. (4) Holds the SOPS age private key in a mounted Secret. (5) Has network access to Git repos. Hardening: (a) Run repo-server with minimal permissions — no ServiceAccount token, no cluster-admin. (b) Use network policies to restrict repo-server egress to only Git repo hosts. (c) Enable Helm template sandboxing (disable `tpl` if not needed). (d) Pin Helm chart versions — never use floating tags. (e) Use RBAC to restrict which repos can be added to ArgoCD. (f) Monitor repo-server logs for unusual activity (unexpected repos cloned, rendering errors). (g) Consider running repo-server in a separate, isolated node pool. (h) Use SOPS with KMS (cloud) instead of local age key files to reduce key exposure. (i) Implement PodSecurityStandards on the argocd namespace (restricted profile with exceptions for repo-server).

---

**Q25: You need to migrate from Sealed Secrets to SOPS + age for an existing cluster with 50 encrypted secrets. Design the migration plan with zero downtime.**

*Expected answer:* Phase 1 — Parallel operation: (1) Generate age keypair and configure `.sops.yaml`. (2) Inject age key into ArgoCD repo-server. (3) Install KSOPS plugin alongside existing Sealed Secrets controller. (4) For each secret: decrypt the SealedSecret (using kubeseal CLI), re-encrypt with SOPS (`sops --encrypt`), create KSOPS generator reference in kustomization.yaml. Do this for 2-3 secrets first as a pilot. Phase 2 — Incremental migration: (5) Migrate secrets in batches (5-10 at a time). For each batch: add the SOPS-encrypted version to Git, update the Kustomize generators, remove the SealedSecret resource from Git. ArgoCD syncs: creates the new Secret (from SOPS), deletes the SealedSecret CR. The underlying Kubernetes Secret remains unchanged because both the SealedSecret and SOPS generate the same Secret with the same name/namespace/data. Zero downtime: pods reference the Secret by name, not by how it was created. Phase 3 — Cleanup: (6) After all 50 secrets are migrated, remove the Sealed Secrets controller. (7) Remove the SealedSecret CRD (ArgoCD prune). (8) Verify all Applications are Synced + Healthy. Key risk: if the SealedSecret and SOPS Secret have different data field names, the transition causes a brief mismatch. Always verify field names match before removing the SealedSecret version.

---

## Sources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/en/latest/)
- [ArgoCD 3.3 Release — InfoQ](https://www.infoq.com/news/2026/02/argocd-33/)
- [ArgoCD vs FluxCD 2026 Comparison — DEV Community](https://dev.to/mechcloud_academy/the-gitops-standard-in-2026-a-comparative-research-analysis-of-argocd-and-fluxcd-46d8)
- [AWS GitOps Tools Comparison](https://docs.aws.amazon.com/prescriptive-guidance/latest/eks-gitops-tools/comparison.html)
- [FluxCD Documentation](https://fluxcd.io/)
- [Rancher Fleet Architecture](https://ranchermanager.docs.rancher.com/integrations-in-rancher/fleet/architecture)
- [Fleet Documentation](https://fleet.rancher.io/)
- [KSOPS — Kustomize SOPS Plugin](https://github.com/viaduct-ai/kustomize-sops)
- [SOPS + Age ArgoCD Integration Guide](https://oneuptime.com/blog/post/2026-02-09-sops-age-encryption-kubernetes-secrets/view)
- [ArgoCD SOPS Config Management Plugin](https://oneuptime.com/blog/post/2026-02-26-argocd-sops-config-management-plugin/view)
- [ArgoCD ApplicationSet Progressive Syncs](https://argo-cd.readthedocs.io/en/latest/operator-manual/applicationset/Progressive-Syncs/)
- [ArgoCD Reconciliation — Rafay](https://rafay.co/ai-and-cloud-native-blog/understanding-argocd-reconciliation-how-it-works-why-it-matters-and-best-practices)
- [Kubernetes Secrets Management 2026 — Infisical](https://infisical.com/blog/kubernetes-secrets-management)
- [ArgoCD Repo Structure Best Practices — Codefresh](https://codefresh.io/blog/how-to-structure-your-argo-cd-repositories-using-application-sets/)
- [ArgoCD Application vs ApplicationSet — Gluo](https://gluo.be/argo-cd-application-vs-applicationset-whats-the-difference/)
