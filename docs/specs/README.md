# manbok — functional specifications

The source of truth for what manbok does, written from the consumer's seat. Bar: throw the
code away and rebuild the product from these files alone, identical external behavior.

Read `CLAUDE.md` here before writing or editing any spec.

## Index

| File | Specifies |
|---|---|
| `glossary.md` | The ontology — nouns, verbs, categorical boundaries. Every spec speaks these. |
| `overview.md` | What the product is, its surfaces, invariants, and the CLI touchpoints. |
| `popover.md` | Menu bar icon states + the popover: header, session list, rows, export gestures, empty/permission states. |
| `settings.md` | Settings window: buffer duration, start at login, failure behavior. |
| `lifecycle.md` | Launch, first-run permission, single instance, quit, LaunchAgent migration. |
| `interfaces/ipc.md` | The Unix-socket IPC boundary at validation precision (verbs, NDJSON responses, error codes). |

## Update protocol

Behavior change → spec updates first or with the change, driven by an intent decision
(`docs/decisions/`). New functionality that doesn't fit an existing file gets a new node,
linked here. Keep cross-references live; the acceptance bar is derived from
`interfaces/` specs post-implementation by qa-dev.

## Provenance

First graduated 2026-07-05 from the gated menubar-app design cycle (internal planning
artifacts, not tracked here) plus the decision records in `docs/decisions/`.
