# IPC server order check

Question: can a slow, silent, hostile or disconnecting client make the daemon unreachable for other clients, or kill it?

Model: `ipc.model.mjs` (hand-copied from `Sources/ManbokPlatform/IPC/UnixSocketServer.swift`). Time is counted in ticks of 1 s.
`check.mjs` is a copy of the formal-verification skill script, so the check runs without the skill installed.
Method: order check (bounded search over every order of events). It is not a proof; "holds" is true only inside the bounds below.

## Rules

| Rule | In plain words | Source |
|---|---|---|
| PingBound | A normal client's PING is answered within one tick (the 1 s read deadline / send timeout) for each client that connected before it, while those clients misbehave (send nothing, do not read the reply, close early). A PING behind a STOP is exempt because the process exits. | `UnixSocketServer.swift:100-111` (`SO_SNDTIMEO`), `:67-84` (serialized accept loop), `:189-217` (`readLine`, one `poll` deadline), `:219-233` (`writeLine`) |
| ReplyOwn | A client that gets a reply gets the reply to its own request, never another client's. | `:113-137` (one request per connection, reply is a local value written on the same fd) |
| NoSigpipe | No client behaviour kills the app with SIGPIPE. | `:104` (`SO_NOSIGPIPE` on every accepted socket), `:100-111` (a peer that is already gone makes `setsockopt` fail; the client is dropped) |
| NoDeadlock | The server never gets stuck with nothing left to do. | whole loop |

"A client never hangs past its timeout" (client side) is not a rule of this model: see "Not modelled".

## Runs

All from the worktree root. Exit codes: 0 every rule holds, 1 a rule breaks, 2 model error, 3 stopped at a cap.
Bounds: up to 3 clients, 7 ticks, request cap scaled to 4 bytes. Default variant = the fixed code (commit a13a11c).

| Command | Result | States | Exit |
|---|---|---|---|
| `node Tests/verify/ipc/check.mjs Tests/verify/ipc/ipc.model.mjs` (variant `current`) | 4 rules hold | 12,825, depth 19 | 0 |
| `MODEL_VARIANT=current-pre-fix node Tests/verify/ipc/check.mjs Tests/verify/ipc/ipc.model.mjs` | PingBound breaks (finding F2, fixed in a13a11c) | 24,938, depth 21 | 1 |
| `MODEL_VARIANT=limit node ...` | PingBound breaks (documented KNOWN LIMIT: a slow DUMP handler delays other clients) | 30,604, depth 22 | 1 |

Client kinds in `current`: ping, idle (sends nothing), non-reading, closes before accept, closes after sending, trickle (one byte per tick, no newline), flood (4096 bytes without newline at once), STOP.

## Finding F2 (fixed)

Before the fix `readLine` relied on `SO_RCVTIMEO`, which restarts on every received byte, so a client sending one byte every 0.4 s held the serialized accept loop up to the 4096-byte cap (about 68 min at 1 byte/s) and another client's PING got no reply.
Model path (variant `current-pre-fix`): trickle client connects, ping client connects, the server accepts the trickle client, two ticks pass, the PING is two ticks old behind one client.
Replay: `Tests/ManbokPlatformTests/IPCModelReplayTests.swift`. Before the fix it failed (`R1_STRICT=1` run, saved in the handoff); after commit a13a11c (`readLine` polls against one 1 s deadline) it passes.

## Mutants (one per rule; each seen to break its rule in the model, run with the default bounds)

| Mutant (`MODEL_VARIANT=`) | What it removes | Broken rule | States | Exit | Replay against real code (production line removed temporarily, test seen to fail, line restored) |
|---|---|---|---|---|---|
| `m-no-timeouts` | the read deadline and the send timeout (pre-B3 server) | PingBound (idle client blocks the loop) | 36,226 | 1 | read deadline: `poll(..., -1)` fails `IPCReliabilityReplayTests.test_idleClientDoesNotBlockOtherClients` |
| `m-no-send-timeout` | `SO_SNDTIMEO` only | PingBound (client that never reads its reply) | 20,100 | 1 | `SO_SNDTIMEO` removed fails `test_nonReadingClientDoesNotBlockOtherClients` |
| `m-no-nosigpipe` | `SO_NOSIGPIPE` | NoSigpipe (client closes while the handler runs) | 11,791 | 1 | `SO_NOSIGPIPE` removed fails `test_clientDisconnectingBeforeReplyDoesNotRaiseSIGPIPE` (this test needed a 0.1 s wait before the client closes, added in this change: without it the server dropped the client before writing and the test passed with the mutant) |
| `m-shared-response` | per-request reply value; one slot shared by all connections | ReplyOwn (the flood client gets another client's reply) | 12,825 | 1 | none: the real reply is a local value, there is no production line to remove |
| `current-pre-fix` | one total deadline (per-read timeout instead) | PingBound (trickle) | 24,938 | 1 | per-read timeout (`remaining = totalTimeout`) fails `IPCModelReplayTests.test_slowTricklingClientDoesNotBlockOtherClients` |

## Not modelled

- Listen backlog of 8 (the model has at most 3 clients).
- Mixed timing: the model has no sub-tick time; a byte arriving just before the deadline is treated like any other byte in that tick.
- Request contents beyond the verb class. A non-reading client needs a reply larger than the socket buffer (for example SESSIONS with many sessions); a small PONG never blocks the server.
- Client side (`UnixSocketClient`): its timeout means "no progress for N s" (`UnixSocketClient.swift:5-8`), not a total deadline. Our server writes a reply in one `write`, so a reply never trickles; a foreign server that trickled could hold a client past its timeout.
- Handler duration beyond a constant per kind (STOP 2 ticks, slow DUMP 3 ticks); the handler itself.
- A client that gives up and closes while the server waits on it (the model assumes nobody ever closes).
- More than 3 clients, and the real effects of STOP (modelled as: answered, then exit).
