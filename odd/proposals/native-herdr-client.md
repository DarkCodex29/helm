# Proposal: helm as a native herdr client

**Status**: not started, not recommended as the next piece of work
**Written**: 2026-10-04, from measurements taken the same day
**Decision owner**: Gian

## The problem this would solve

herdr draws a sidebar and a tab row inside the terminal. On a 27" screen
that is orientation. On a 6" phone it is chrome that restates what helm's
own drawer and tab strip already show, and it costs rows of terminal in
every frame.

Reported three times from the device as the stray `switch` and the
`tab Helm · 8/10` row.

## What was measured, not assumed

All on herdr 0.9.0, 2026-10-04, against throwaway sessions where noted so
the owner's screen never moved.

| Question | Method | Answer |
| --- | --- | --- |
| Does `HERDR_CONFIG_PATH` change the chrome? | A/B on a fresh session, control vs hidden-sidebar config | **No** — byte-identical renders |
| Does the server read that file at all? | started a server with an enum value that cannot parse | **No** — `config check` rejects it, the server comes up clean |
| Does it work for a SECOND client on a live server? | attached a second client with its own config | **No** — sidebar drawn in both |
| Can a plugin hide chrome? | full plugin API surface | **No** — `action.*`, `pane.*`, `log.list`, `enable/disable`, `link/unlink`. No chrome, no per-client rendering |
| Is there a per-client mechanism at all? | socket API schema | **Yes** — `client_shell.surface.set` |
| Can helm call it today? | called it over the session socket | **No** — `connection_local_only`: "only available through a client shell endpoint" |

A server that starts happily on a config it would have rejected never read
it. That single experiment is what settles the config path, and it is
cheaper than comparing renders.

## The mechanism that exists

`client_shell.surface.set` — *"Updates whether the requesting client shell
receives and controls pane presentation."* Per client, lease-based, with a
negotiated `surface_interest` server capability. It is the primitive for a
client that draws panes itself, which is exactly what helm is already
doing for tabs, navigation, and the keyboard.

It is restricted to client-shell endpoints. helm is not one: it opens SSH,
runs the `herdr` binary in a PTY, and paints what that process emits. The
client shell is herdr on the Mac, not the app.

## What the change actually is

helm stops running `herdr` in a terminal and starts speaking its socket
protocol:

- the client-shell handshake, protocol 22, including capability negotiation
- surface lease acquisition and release, including what happens when the
  lease is lost mid-session
- pane presentation: content, geometry, splits, focus, scrollback
- layout, resize, and the events that drive them
- a fallback path for a herdr too old to offer `surface_interest`, and for
  tmux and zellij, which have no equivalent at all

That last point is the real cost. helm supports three multiplexers. This
would make one of them structurally different from the other two, and the
PTY path has to stay for them regardless. The win is not "replace the
terminal" — it is "maintain two renderers".

## Why this is not the next piece of work

1. **It replaces the piece everything else stands on.** The PTY render is
   under the keyboard, the tab strip, the file browser, and agents. All
   four changed today.
2. **The payoff is real but bounded**: roughly two terminal rows and a
   cleaner frame, against reimplementing a renderer.
3. **There is no partial version.** A half-migrated client either holds the
   surface lease or does not.
4. **It is upstream-shaped.** An unconditional `hide_tab_bar`, or
   per-client chrome in config, is a flag in herdr's own config and solves
   this for every client of every herdr. Worth asking for even if the
   answer is slow, because this proposal is the cost of not asking.

## If it is ever started

Order that keeps a working app at every step:

1. Speak the protocol READ-ONLY alongside the PTY — subscribe, parse, and
   assert the parsed state matches what the PTY shows. No rendering.
2. Only once that agrees for a week of real use, take the surface lease
   behind a setting, defaulting off.
3. Render panes from the protocol with the PTY path still present and one
   switch between them.
4. Remove nothing until the protocol path has survived the same device
   validation the PTY path has.

Step 1 is also the cheapest way to find out whether the protocol exposes
what the render needs, without betting the app on the answer.
