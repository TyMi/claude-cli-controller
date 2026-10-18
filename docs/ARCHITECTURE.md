# Architecture

## Overview

```
LXC container (boot)
   └── systemd: claude-cli-controller.service
          └── controller.sh supervise
                 ├── tmux (socket: ~/.local/state/claude-cli-controller/tmux.sock)
                 │      ├── session "main"    -> claude (cwd: project-a)
                 │      ├── session "support" -> claude --continue (cwd: project-b)
                 │      └── session "sandbox" -> claude (cwd: scratch)
                 └── watchdog loop (every N seconds: restart missing sessions,
                                    write readable snapshots)
```

## Why tmux?

Claude Code is primarily an interactive REPL. So that sessions keep running
after the container boots without a logged-in user, and can still be entered
later via SSH, each session runs in its own **detached tmux session**:

- The session stays alive even if nobody is connected.
- Several people/tools can attach independently with `tmux attach`.
- A dedicated tmux socket (`tmux -S <sock>`) separates the controller's
  sessions from the user's personal `tmux`, in case they also use it
  interactively.

## Why a custom watchdog instead of just `Restart=on-failure`?

`systemd` only watches the service's main process (`controller.sh
supervise`), not the individual tmux panes/Claude processes inside it. If a
single Claude session crashes, systemd would not notice. The supervisor loop
in `controller.sh` therefore checks every configured session periodically
and restarts it if needed — the systemd restart only applies if the
controller process itself crashes.

The supervisor re-reads `sessions.conf` on every tick, so `new`, `archive`,
`unarchive` and `edit` take effect without restarting the service.

## Behavior worth knowing

- **Backoff**: a session that keeps failing to start is retried with growing
  pauses (15s → … → 15min) instead of every tick; state lives in
  `backoff/<name>` (see `docs/SESSIONS.md`).
- **Remote Control**: sessions start with `--remote-control <name>` so they
  show up in the Remote Control / fleet overview (`CLAUDE_CTRL_REMOTE_CONTROL=0` disables it).
- **Auto-trust**: directories created by `new` are marked as trusted in
  `~/.claude.json`, so an unattended session does not hang at the trust
  prompt (`CLAUDE_CTRL_AUTO_TRUST=0` disables it).
- **Logs & snapshots**: the full raw pane output goes to `logs/<name>.log`
  (`tmux pipe-pane`); the supervisor additionally overwrites a readable
  `logs/<name>.snapshot.txt` on every tick.
- **Shutdown**: `supervise` traps TERM/INT and stops all sessions in
  parallel (two Ctrl-C within ~1s, then `kill-session` after at most ~10s).
  The unit therefore has no `ExecStop`.

## Components

| File/directory | Purpose |
|----------------|---------|
| `controller.sh` | Start/stop/status/supervise logic and session management |
| `config/sessions.conf` | Which sessions run with which options (created from `config/sessions.conf.example` or by `new`) |
| `systemd/claude-cli-controller.service` | Autostart definition for the container |
| `logrotate/claude-cli-controller.conf` | Log rotation for `.../logs/*.log` |
| `completions/claude-cli-controller.bash` | Bash completion (optional) |
| `test/controller.bats`, `.github/workflows/ci.yml` | Regression tests + CI (shellcheck + bats + gitleaks) |
| `docs/` | This documentation |
| `~/.local/state/claude-cli-controller/` | Runtime data: tmux socket, `logs/` (transcript + snapshot per session), `backoff/` (failed attempts per session), `backups/` (default target of `controller.sh backup`) |

## Non-goals (deliberately left out)

- No own auth/secrets management: Claude Code uses the regular login session
  (`~/.claude/`) or the `ANTHROPIC_API_KEY` of the user the service runs as.
- No web UI/API — access is via SSH + `tmux attach` or
  `controller.sh status/attach`.
- No multi-host orchestration — the controller manages sessions within a
  single LXC container only.
