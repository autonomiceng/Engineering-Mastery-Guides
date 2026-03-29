# AGENTS.md

This repository is a publishing workspace for LLM-assisted technical books and study guides.
Any agent operating in this repository must follow these rules unless the user explicitly overrides them.

## Repository Purpose

- The repository contains multiple long-form books and study guides.
- Books live in their own top-level directories.
- Generated content is expected to be manually reviewed by the maintainer before being treated as authoritative.
- The quality bar is professional publishing quality, not rough brainstorming output.

## Global Operating Rules

- Do not explain beginner concepts unless the book explicitly targets beginners.
- Prefer precise, technical, source-grounded writing over motivational or promotional language.
- Never guess when a claim is ambiguous, version-sensitive, vendor-specific, or likely to drift.
- When current facts matter, verify against reliable primary sources and documentation.
- Treat all generated infrastructure, automation, and shell commands as review-required until validated.
- Keep repository structure stable and predictable.
- Do not silently invent files, chapter names, or folder layouts that conflict with existing conventions.

## Content Disclosure Rules

- LLM-generated content must remain clearly framed as draft material until manually reviewed.
- Do not remove or weaken disclosure language without explicit user direction.
- Do not imply that generated code or prose has been validated if it has not been validated.

## Book Layout Rules

For every book in this repository:

- The book directory lives at the repository top level.
- Narrative chapter files live at the top of that directory.
- Lab assets live under `src/chapter_XX/`.
- Chapter filenames should follow `chapter_XX_short_topic.md`.
- Supporting navigation files such as `README.md`, `INTRODUCTION.md`, and `TABLE_OF_CONTENTS.md` should be GitHub-friendly and readable directly in the web UI.

## Workflow Rules For Writing Books

Before generating or revising book content:

1. Read the local book prompt, table of contents, and any directly referenced repository documents.
2. Align the output to the target audience and stated delivery constraints.
3. Preserve chapter numbering, filesystem layout, and naming conventions.
4. If a proposed structural improvement exists in the book materials, treat it as part of the active contract unless the user rejects it.

When writing chapters:

1. Write to the filesystem, not just to chat.
2. Create or update the matching lab assets under `src/chapter_XX/`.
3. Keep labs concrete and file-backed.
4. Prefer reusable shared inputs such as `constants.yaml` when the book contract calls for them.
5. Do not ask for permission between chapters if the active prompt says to continue automatically.

## Structural Standard For Technical Chapters

Unless a book explicitly defines a different standard, every chapter should follow this internal rhythm:

1. Title and architectural deep dive
2. Failure modes and operational consequences
3. Competitive landscape analysis
4. Under the hood: Linux, kernel, or infrastructure internals
5. Cloud versus on-prem context
6. Follow-along exercise with real files
7. Senior-level interview questions with answer rubrics

This structure is mandatory for `platform-expert-kubernetes-at-scale` because its table of contents explicitly defines it as a proposed improvement to adopt.

## Quality Standard For Comparisons

- Comparisons must identify why an option wins, where it fails, and what tradeoff is being paid.
- Avoid vague rankings such as "best" without context.
- Prefer explicit criteria such as operational complexity, failure recovery, security posture, cost model, ecosystem maturity, and fit for cloud versus on-prem environments.

## Quality Standard For Labs

- Labs must leave behind real files in the repository.
- Avoid pseudo-code when actual manifests, playbooks, or configuration files are expected.
- Keep path references accurate.
- Reuse existing repository patterns before inventing new ones.
- Prefer secure defaults and call out assumptions.

## Source And Validation Rules

- When freshness matters, use current reliable sources and prioritize official documentation.
- Distinguish clearly between sourced facts, engineering judgment, and inference.
- Do not cite trend claims or vendor behavior casually.

## Precedence Rules

- Repository-level `AGENTS.md` defines the default operating contract.
- A book-local prompt such as `PROMPTS.md` may add tighter, book-specific constraints.
- If the two conflict, follow the more specific instruction unless it would reduce accuracy or violate an explicit user instruction.
