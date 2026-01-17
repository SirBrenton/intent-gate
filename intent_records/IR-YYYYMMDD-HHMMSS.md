# Intent Record: IR-20260117-091500

## Human
name: Brent Williams
attestation: I authorize the actions below. I understand they may be destructive.

## Scope
root: /Users/brentwilliams/intent-gate/sandbox
expires: 2026-01-17T11:15:00-08:00

## Allowed action classes
- write_over_existing
- delete
- move_or_rename

## Constraints
- max_files: 20
- deny_globs:
  - "**/.git/**"
  - "**/secrets/**"
  - "**/*.key"
  - "**/*.pem"

## Change ticket (optional)
reason: "Refactor filenames to kebab-case; remove duplicates."

## Signature
method: local
signature: sha256(<this file contents without this line>) = TBD