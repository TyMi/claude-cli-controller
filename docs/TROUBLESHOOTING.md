# Troubleshooting

Note: messages printed by `controller.sh` are in German; they are quoted
as-is below.

## Service starts, but no session is running

```bash
journalctl -u claude-cli-controller.service -e
```

Common causes:

- `claude` is not in the `PATH` of the service environment. Fix: set an
  absolute path in `CLAUDE_BIN` (an `Environment=` line in the `.service`
  file) or add `PATH=` explicitly in the unit.
- `tmux` is not installed (`sudo apt install tmux`).
- The `workdir` from `sessions.conf` does not exist (`Arbeitsverzeichnis
  fehlt` in the journal) → the session is retried with backoff, see
  `docs/SESSIONS.md`.

## "claude: command not found" only under systemd, works manually

systemd services do not inherit `~/.bashrc`/`~/.profile`. Find where
`claude` lives (`which claude` as `<user>`) and set the path explicitly in
the unit, e.g.:

```ini
Environment=PATH=/home/<user>/.local/bin:/usr/local/bin:/usr/bin:/bin
```

## Claude asks for login / authentication

The service runs as `<user>` without an interactive terminal. Log in once
interactively as `<user>` beforehand (`claude login`), or provide an
`ANTHROPIC_API_KEY` via `/etc/claude-cli-controller.env` (see
`docs/SETUP.md`, step 3) — **not** directly as an `Environment=` line in the
unit, which would be readable by every local user via `systemctl show`.

## Session hangs at the "Trust this folder?" dialog

Only affects sessions that were not created with `controller.sh new` (e.g.
entered into `sessions.conf` by hand, or `new` with an already existing
directory) — `new` marks directories it creates itself as trusted
automatically. Fix:

```bash
./controller.sh trust <nr|name>     # marks the session's workdir as trusted
tmux -S ~/.local/state/claude-cli-controller/tmux.sock kill-session -t <name>
./controller.sh start               # (or wait for the supervisor's next tick)
```

Alternatively, confirm the dialog once via `./controller.sh attach <name>`.

If the dialog still appears after `trust`: `~/.claude.json` is rewritten as a
whole and running `claude` processes write to it as well, so a concurrent
write can overwrite the change — run `trust` again. If the workdir is a
symlink, `trust` stores the resolved path, which may differ from the path
`claude` uses; confirm the dialog once via `attach` in that case.

## Session hangs / does not respond

```bash
./controller.sh attach <name>
# take a look; a single Ctrl-C does NOT exit Claude Code (it only shows
# "Press Ctrl-C again to exit" and needs a second Ctrl-C within ~1s, see
# docs/SESSIONS.md) - afterwards Ctrl-b d detaches
```

If that does not help:

```bash
tmux -S ~/.local/state/claude-cli-controller/tmux.sock kill-session -t <name>
./controller.sh start
```

## A session keeps failing (`[failed: N Versuche, ...]` in `status`/`list`)

The session could not be started N times in a row and is now retried only
every few minutes (backoff, up to 15min). Look at the transcript and the
snapshot under `~/.local/state/claude-cli-controller/logs/<name>.log` and
`<name>.snapshot.txt`. Typical causes: `resume` is `last` but the workdir has
no conversation yet (`No conversation found to continue`), the workdir is
missing, or `claude` is not logged in. After fixing the cause, the next
successful start resets the counter.

## Log files grow without bound

A ready-made `logrotate` config is included at
`logrotate/claude-cli-controller.conf` (installation: see `docs/SETUP.md`,
step 5). `copytruncate` is required there because tmux `pipe-pane` keeps the
file open — a normal rename+recreate would not be noticed by the running
`pipe-pane` instance.

The `.snapshot.txt` files (periodic plain-text snapshot, see
`docs/SESSIONS.md`) need no rotation since they are overwritten, not
appended to, on every supervisor tick.

## After a restart the desktop app connects to a new, empty session

Remote Control was active, but the desktop app shows no previous
conversation and starts empty. Cause: `resume` is empty in `sessions.conf`,
so `claude` starts a **new** conversation on every `start`/`supervise` (also
after a container/host restart) — `--remote-control` then only enables Remote
Control for that new, empty session. The old conversation is preserved but is
no longer the one Remote Control connects to.

Fix: set `resume` to `last`, so `build_cmd` builds `claude --continue
--remote-control <name>` instead (see `docs/SESSIONS.md`):

```bash
./controller.sh edit <nr|name> --resume last
```

or in `sessions.conf`:

```
main;/home/<user>/projects/project-a;last;;active
```

This only takes effect the next time the session starts — running sessions
are skipped by `start_one` (`session_exists`), so restart the affected
session once (`./controller.sh restart` restarts all).

## Container restart does not bring the sessions back

- Check whether the service is enabled: `systemctl is-enabled claude-cli-controller.service`
- Check whether the LXC container itself has `onboot: 1` (host side,
  outside this project).
