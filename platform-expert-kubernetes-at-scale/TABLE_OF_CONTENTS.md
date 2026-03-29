# Table of Contents

## Book Title

**From Linux Admin to Platform Expert: Kubernetes at Scale**

## Reading Path

| Chapter | Focus | Status | Labs |
| --- | --- | --- | --- |
| [Chapter 1: Deconstructing the Control Plane & Cluster Bootstrap](./chapter_01_control_plane.md) | etcd, kube-apiserver, scheduler, controller-manager, RKE2, kube-vip, quorum and bootstrap mechanics | Draft present | `src/chapter_01/` |
| [Chapter 2: GitOps, Fleet Management & Secrets](./chapter_02_gitops_secrets.md) | Argo CD, Rancher, SOPS, age, drift management, repo structure, secret bootstrapping | Draft present | `src/chapter_02/` |
| Chapter 3: The Worker Node & Virtualization | kubelet, CRI, cgroups v2, CPU and memory isolation, KubeVirt, vCluster | Planned | `src/chapter_03/` |
| Chapter 4: Advanced Networking & North-South Entry | Cilium, eBPF, Gateway API, BGP, cert-manager, private DNS | Planned | `src/chapter_04/` |
| Chapter 5: Persistent Storage at Scale | CSI internals, Longhorn, EBS, Persistent Disk, Azure Disks, failure domains | Planned | `src/chapter_05/` |
| Chapter 6: Cloud Managed Kubernetes | EKS, GKE, AKS control-plane constraints, IAM integration, feature gaps, operational tradeoffs | Planned | `src/chapter_06/` |
| Chapter 7: Scaling & Scheduling | HPA, VPA, Cluster Autoscaler, Karpenter, affinities, taints, topology policy | Planned | `src/chapter_07/` |
| Chapter 8: Day 2 Operations & Disaster Recovery | observability, backups, restore drills, SLO thinking, failure injection | Planned | `src/chapter_08/` |

## Proposed Structural Improvement

The original syllabus is strong, but the material will read better if every chapter keeps the same internal rhythm:

1. Architectural deep dive
2. Failure modes and operational consequences
3. Competitive landscape analysis
4. Linux or infrastructure internals
5. Cloud versus on-prem comparison
6. Follow-along lab
7. Senior-level interview questions

That keeps the narrative consistent while still supporting deep technical detail.

## Book Assets

- Narrative chapters: top-level `chapter_XX_*.md`
- Chapter labs: `src/chapter_XX/`
- Prompting and generation notes: [PROMPTS.md](./PROMPTS.md)
