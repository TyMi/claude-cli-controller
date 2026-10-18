# claude-cli-controller

![Built with AI](https://img.shields.io/badge/Built_with-AI-success)
[![CI](https://github.com/TyMi/claude-cli-controller/actions/workflows/ci.yml/badge.svg)](https://github.com/TyMi/claude-cli-controller/actions/workflows/ci.yml)

Starts, supervises and manages multiple Claude Code CLI sessions centrally in
an LXC container. Each session runs as a detached `tmux` session; a systemd
service starts all configured sessions when the container boots and keeps
them alive afterwards.

> Note: the CLI output (log lines, errors, `--help`) is in German; the
> documentation is in English.

## Quick start

```bash
# 1. Create a new project: create the directory, register it, start it
./controller.sh new my-project

# 2. Overview & usage
./controller.sh list                  # numbered overview of all sessions
./controller.sh attach my-project     # or by number: attach 1
# inside tmux: Ctrl-b d detaches (the session keeps running)

# 3. Archive a session (stop it, no autostart anymore)
./controller.sh archive my-project    # or by number: archive 1

# 4. Run permanently as a systemd service -> see docs/SETUP.md
```

## Commands

| Command | Effect |
|---------|--------|
| `controller.sh new <name> [workdir] [resume] [extra_args]` | Create the project directory, register it in the config, start it right away |
| `controller.sh list` | Numbered overview of all sessions (including archived ones) |
| `controller.sh attach <nr\|name>` | Attach to a running session |
| `controller.sh archive <nr\|name>` | Stop a session and archive it (no autostart anymore) |
| `controller.sh unarchive <nr\|name>` | Re-activate an archived session (start it separately) |
| `controller.sh rename <nr\|name> <new-name>` | Rename a session (config, running tmux session, log files) |
| `controller.sh edit <nr\|name> [--workdir ...] [--resume ...] [--extra-args ...]` | Change config fields (effective at the next start of that session) |
| `controller.sh trust <nr\|name>` | Mark the session's workdir as trusted in `~/.claude.json` (for existing directories) |
| `controller.sh delete <nr\|name> [--purge-workdir [--force]]` | Remove a session, optionally including its directory |
| `controller.sh start` | Start all active sessions (idempotent, skips archived ones) |
| `controller.sh stop` | Stop all sessions |
| `controller.sh restart` | Stop + start |
| `controller.sh status [--json]` | Show running/stopped sessions (optionally machine-readable) |
| `controller.sh supervise` | Start + endless watchdog (entry point for systemd) |
| `controller.sh backup [target]` / `restore <file> --force` | Back up / restore the config and `~/.claude/` |

`<nr|name>` is either the number shown by `list` or the session name.

## Configuration (environment variables)

All variables are optional.

| Variable | Default | Meaning |
|----------|---------|---------|
| `CLAUDE_CTRL_CONFIG` | `<repo>/config/sessions.conf` | Path of the session config |
| `CLAUDE_CTRL_STATE_DIR` | `~/.local/state/claude-cli-controller` | tmux socket, `logs/`, `backoff/`, `backups/` |
| `CLAUDE_CTRL_PROJECTS_DIR` | `~/projects` | Base directory for projects created with `new` (also the safety boundary of `delete --purge-workdir`) |
| `CLAUDE_CTRL_INTERVAL` | `15` | Seconds between two supervisor ticks |
| `CLAUDE_CTRL_CLAUDE_JSON` | `~/.claude.json` | Claude Code state file used for auto-trust |
| `CLAUDE_CTRL_AUTO_TRUST` | `1` | `0` = do not mark newly created project directories as trusted |
| `CLAUDE_CTRL_REMOTE_CONTROL` | `1` | `0` = do not start sessions with `--remote-control <name>` |
| `CLAUDE_BIN` | `claude` | Claude Code executable (use an absolute path under systemd) |

## Tests

```bash
sudo apt-get install -y shellcheck bats tmux python3
shellcheck controller.sh
bats test/controller.bats    # needs a UTF-8 locale, e.g. LC_ALL=C.UTF-8
```

Runs on every push/PR via GitHub Actions (see the badge above). The bats
suite covers previously found and fixed problems as permanent regression
tests (shell injection via the session name, backoff, purge guard rails,
`resume` validation, config field validation, ...). A third CI job
(`gitleaks`) scans every push/PR against the full git history for
accidentally committed secrets.

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — how the components fit together
- [Setup](docs/SETUP.md) — LXC container + systemd, step by step
- [Sessions](docs/SESSIONS.md) — config format, resume behavior, logs, backoff
- [Troubleshooting](docs/TROUBLESHOOTING.md) — known problems and fixes
- [Security policy](SECURITY.md) — how to report a vulnerability privately

## License

[MIT](LICENSE)
