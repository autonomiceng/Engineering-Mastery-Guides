# LLM Disclosure And Review Policy

## Repository Status

This repository contains LLM-assisted drafts.
Generated material is used to accelerate research organization, first-pass writing, comparison framing, and infrastructure scaffolding.
It is not automatically treated as correct, complete, or safe.

## What Was Generated

Depending on the file, LLM assistance may have been used for:

- Book outlines and chapter structure
- Markdown narrative drafts
- Example OpenTofu, Ansible, and Kubernetes manifests
- Comparison tables and interview-question scaffolding
- Repository boilerplate and editorial copy

## What Still Requires Human Review

Every book and lab in this repository should be assumed to require manual review for:

- Technical accuracy
- Operational safety
- Version drift
- Vendor-specific behavior
- Security implications
- Clarity and coherence

## Reader Guidance

- Do not apply infrastructure examples blindly.
- Validate generated claims against primary documentation and live system behavior.
- Treat all code and commands as draft material until reviewed in your own environment.

## Maintainer Intent

The intended workflow is:

1. Generate a structured draft quickly.
2. Manually review the material for correctness and omissions.
3. Rewrite or remove weak sections.
4. Validate labs in isolated environments.
5. Publish only after review reaches the required quality bar.

## Disclosure Standard For Contributions

Contributors should explicitly disclose meaningful AI assistance in pull requests or commits when generated output materially influenced the result.
