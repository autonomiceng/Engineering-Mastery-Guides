# Contributing

## Contribution Principles

This repository values correctness over volume.
Contributions should improve technical accuracy, clarity, reproducibility, or maintainability.

## Before You Open A PR

- Verify the change is scoped and intentional.
- Call out whether the contribution affects narrative content, lab code, or repository metadata.
- If AI was used to generate or rewrite any portion of the change, disclose that in the pull request.
- Do not present unverified generated output as reviewed fact.

## Content Changes

When editing book chapters or introductions:

- Preserve the target audience: experienced engineers
- Avoid beginner-level padding
- Prefer precise operational detail over marketing language
- Flag claims that still need validation rather than guessing

## Lab Changes

When editing files under any `src/` directory:

- Keep examples runnable in principle, not merely illustrative
- Document assumptions and prerequisites
- Avoid embedded credentials, private endpoints, or environment-specific values
- Favor secure defaults where practical

## Pull Request Checklist

- Explain what changed and why
- List files or sections that still need manual verification
- Mention any generated content
- Note any commands or checks used to validate the change

## Issues

Open an issue for:

- Technical inaccuracies
- Broken lab assets
- Unsafe defaults
- Contradictory or outdated guidance
- Repository metadata or documentation gaps
