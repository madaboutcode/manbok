# Menu bar app process model, CLI role, and always-on

**Date:** 2026-07-04 · **Cycle:** tasks/2026-07-04-menubar-app/ · **Status:** decided

**Considered:** app + separate daemon (two processes); app *is* the daemon; keeping always-on
via a new IPC mode command; dropping `manbok start`.

**Chosen:** The menu bar app **is** the long-lived process — it owns capture, ring, and the IPC
server (reconfirms draft spec Option A). The launchd LaunchAgent is retired: start-at-login is
an in-app toggle via login-item registration, and the migration must unload/remove any
previously installed LaunchAgent plist so two processes never fight over the socket. The CLI
becomes a thin IPC client: `status`/`dump`/`stop` unchanged; `manbok start` launches the .app
if not running. **Always-on capture is dropped from v1** — opportunistic capture is the
product.

**Why:** One process is simpler and the Core/Platform libraries drop in unchanged; login items
are the native mechanism for menu bar apps; always-on had no traced user job (stakeholder,
2026-07-04).

**Limitations:** With the app not running, CLI ops fail (with a hint) except `start`. Always-on
users of the old CLI lose that path.

**Reversal:** Always-on — a real need appears → add an IPC mode command (e.g. `MODE ALWAYS`);
cheap, two-way. Distribution is local-build/ad-hoc-signed for personal use — revisit signing,
notarization, packaging the day the app is shared with anyone else.
