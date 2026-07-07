# docs/specs/ — spec authority

Before creating, editing, or extracting any spec under this directory, invoke the
`writing-specs` skill if it is available in your environment; otherwise follow the format
rules below strictly.

Read `README.md` in this directory for the spec index and update protocol.

## Format

Every spec file uses this section order (omit sections that genuinely don't apply):

```markdown
# <Name>

PURPOSE — one paragraph: what this specifies and for whom.
CONTENTS — TOC when the file has 4+ sections.
SCOPE — what this file covers / defers to siblings (link them).
REQUIREMENTS — numbered R1, R2, … (sub: R1.1). Each testable from the consumer's seat.
STATES — state inventory + transitions, where behavior is stateful.
EDGE CASES — numbered E1, E2, … failure/boundary behavior.
VERIFICATION — how a tester would exercise this spec's claims.
```

Rules:
- Consumer lens only: what the user/CLI/OS observes. No component names, no framework
  mechanics — implementation lives in ARCHITECTURE.md and CONTRACT blocks, never here.
- Speak the glossary's nouns (`glossary.md`); evolving a term requires a decision record
  in `docs/decisions/`.
- Spec moves only when intent changes (with its decision record) — never to absolve an
  implementation. A failing spec-enforcement test is a bug report against the code.
