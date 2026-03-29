# Engineering Mastery Guides

Curated, deeply technical study guides for experienced infrastructure, platform, and software engineers.

> [!IMPORTANT]
> This repository contains LLM-assisted drafts that are intended to be manually reviewed, corrected, and hardened before being treated as authoritative.

## Overview

This repository is a publishing workspace for long-form technical books and study guides.
The target reader is not a beginner. The material is optimized for engineers who already operate Linux, cloud, and platform systems and want higher-resolution explanations, implementation detail, and practical labs.

## Contents

- Current books
- Repository layout
- Reading order
- Licensing

## Editorial Model

- Long-form books live in their own top-level directories.
- Narrative content is written in Markdown for GitHub-native reading and review.
- Lab assets live beside each book under `src/`.
- LLMs are used to accelerate first drafts, outlines, comparison tables, and lab scaffolding.
- Final quality depends on manual review, validation, and correction.

See [LLM-DISCLOSURE.md](./LLM-DISCLOSURE.md) for the repository-wide disclosure and review policy.

## Current Books

| Book | Focus | Status |
| --- | --- | --- |
| [platform-expert-kubernetes-at-scale](./platform-expert-kubernetes-at-scale/) | Kubernetes internals, platform engineering, RKE2, GitOps, networking, storage, scaling, and disaster recovery | Draft in review |

## Repository Layout

```text
.
|-- AGENTS.md
|-- CODE_OF_CONDUCT.md
|-- CODEOWNERS
|-- CONTRIBUTING.md
|-- LICENSE
|-- LLM-DISCLOSURE.md
|-- README.md
|-- SECURITY.md
|-- .github/
|-- platform-expert-kubernetes-at-scale/
|   |-- INTRODUCTION.md
|   |-- PROMPTS.md
|   |-- README.md
|   |-- TABLE_OF_CONTENTS.md
|   |-- chapter_01_control_plane.md
|   |-- chapter_02_gitops_secrets.md
|   `-- src/
`-- ...
```

## Reading Order

1. Start with the book's [INTRODUCTION.md](./platform-expert-kubernetes-at-scale/INTRODUCTION.md).
2. Use the book's [TABLE_OF_CONTENTS.md](./platform-expert-kubernetes-at-scale/TABLE_OF_CONTENTS.md) to navigate chapters and labs.
3. Treat every lab as draft infrastructure until manually reviewed and tested in an isolated environment.

## Quality Bar

Production-ready repository metadata does not imply production-ready technical content.
The repo is prepared for publishing and iteration, but each book remains subject to technical validation before external use.

## Licensing

This repository uses a dual-license model:

- Written documentation and narrative text are licensed under CC BY 4.0.
- Source code and infrastructure examples under `src/` directories are licensed under MIT.

See [LICENSE](./LICENSE) for the exact terms.
