# Managing sessions & projects

Note: messages printed by `controller.sh` are in German; they are quoted
as-is below.

## Creating a new project (recommended)

```bash
./controller.sh new <name> [workdir] [resume] [extra_args]
```

This does the following in one step:

1. Creates `workdir` (default: `$CLAUDE_CTRL_PROJECTS_DIR/<name>`, i.e.
   `~/projects/<name>`) if it does not exist yet.
2. Registers the session in `config/sessions.conf` (status `active`),
   creating the file if necessary.
3. Starts the session in tmux right away.

Every started session runs with `--remote-control <name>`, so it shows up in
the Remote Control / fleet overview (e.g. `claude.ai/code`, other local
sessions via `ListAgents`) and can be operated from there. Disable with
`CLAUDE_CTRL_REMOTE_CONTROL=0`.

If `resume` is omitted, `new` sets `last` (`--continue`), so the session
survives a container/host restart without losing its conversation context
(see `docs/TROUBLESHOOTING.md`, "After a restart the desktop app connects to
a new, empty session"). If you deliberately want an empty session on every
start (e.g. a sandbox project), pass `resume` explicitly as an empty string
(third parameter `""`, do not omit it).

The very first start by `new` always runs **without** `--continue`,
regardless of the `resume` value: `workdir` was just created, so there is
no conversation yet, and `claude --continue` aborts immediately with `"No
conversation found to continue"` instead of starting fresh. `last` is
still stored in `sessions.conf`, so from the second start on (restart/reboot)
— when the first start has created a conversation — the session continues
normally.

`new` also marks the directory as trusted in `~/.claude.json`
(`hasTrustDialogAccepted=true`). Without this, `claude` would hang at the
interactive trust prompt in the unattended tmux session, since nobody is
there to confirm it. This only applies to directories that `controller.sh`
creates itself — for an already existing directory the dialog is not
bypassed automatically; either confirm it once via `controller.sh attach`
or run `./controller.sh trust <nr|name>` (explicit, works regardless of
`CLAUDE_CTRL_AUTO_TRUST`; takes effect on the next start of a session that
is already running). Disable
auto-trust entirely with `CLAUDE_CTRL_AUTO_TRUST=0`.

`trust` stores the symlink-resolved (`realpath`) path of the workdir, while
`new` stores the path exactly as given. If the workdir is (or lies behind) a
symlink, the entry may not match the path `claude` looks up; in that case
confirm the dialog once via `controller.sh attach`.

`new` and `trust` modify `~/.claude.json` with a read-modify-write of the
whole file, while running `claude` processes update the same file. If a
session writes at the very same moment, one of the two changes can be lost.
If a session still shows the trust dialog after `trust`, simply run `trust`
again.

`workdir`, `resume` and `extra_args` must not contain a semicolon or a line
break (they would corrupt the `sessions.conf` line); `new` and `edit`
reject such values.

Examples:

```bash
# simplest project, the directory is created automatically as ~/projects/customer-a
# resume omitted -> automatically "last" (survives restarts)
./controller.sh new customer-a

# specify your own working directory
./controller.sh new customer-b /srv/repos/customer-b

# with extra flags, resume explicitly empty -> starts fresh on every restart (e.g. sandbox)
./controller.sh new customer-c "" "" "--permission-mode acceptEdits"
```

## Listing sessions (numbered)

```bash
./controller.sh list
```

```
Nr  Status    Läuft    Name                 Workdir
1   active    running  main                 /home/<user>/projects/project-a
2   active    stopped  support              /home/<user>/projects/project-b
3   archived  stopped  oldproject           /home/<user>/projects/oldproject
```

The number refers to the order in `sessions.conf` (comments do not count)
and can be used wherever a name is expected: `attach`, `archive`,
`unarchive`, `rename`, `edit`, `trust`, `delete`.

## Archiving a session

Stops the session and marks it `archived` in the config, so it is no longer
started automatically by `start`/`supervise` (and therefore not after a
container restart either). The entry is kept.

```bash
./controller.sh list            # look up the number
./controller.sh archive 3       # by number
./controller.sh archive oldproject   # or by name
```

If `status` is set to `archived` by hand in `sessions.conf` (instead of via
this command), a session that is still running is **not** stopped
automatically — a warning is logged on every `start`/`supervise` tick
(`... ist als 'archived' markiert, läuft aber noch`). This is deliberate: a
mere typo while editing must not terminate a session that is in active use.
To actually stop it, keep using `controller.sh archive`.

## Re-activating a session

```bash
./controller.sh unarchive 3
./controller.sh start           # then start it explicitly
```

(A running supervisor starts it on its next tick anyway.)

## Format of `config/sessions.conf`

Normally not maintained by hand (see `new`/`archive` above), but for
reference:

```
name;workdir;resume;extra_args;status
```

| Field | Meaning |
|-------|---------|
| `name` | Unique tmux session name. Allowed: letters (including umlauts), digits, spaces, `-`, `_`, max. 64 characters, **at least one letter**. `controller.sh new` rejects anything else, and lines with an invalid name are skipped when the file is read. A purely numeric name (e.g. `"2024"`) is deliberately not allowed: `archive`/`unarchive`/`attach`/`delete` always interpret a number as a list index from `list`, never as a name — such a name could never have been addressed by name |
| `workdir` | Working directory in which `claude` is started. Empty = `$HOME` |
| `resume` | Empty = new session · `last`/`continue` = `--continue` · otherwise = `--resume <uuid>` — only a session UUID of the form `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` is accepted and properly quoted; anything else is discarded (the session then starts without `--resume`, see the security note below) |
| `extra_args` | Additional CLI flags, e.g. `--permission-mode acceptEdits` |
| `status` | `active` (default, empty = active) or `archived` |

Comment lines start with `#`, empty lines are ignored. No semicolons inside
the fields. If the same name appears more than once (e.g. through manual
editing), the first definition wins and all further ones are skipped with a
warning.

**Security note:** `extra_args` ends up unquoted in the command string that
`tmux new-session` executes as a shell command — this field is effectively
shell code, so only trusted, self-maintained values belong there, never
input from untrusted sources. `name` (character allowlist, see above) and
`resume` (only `last`/`continue`/UUID, anything else is discarded) are
validated and properly quoted — `name` among other things because it is also
used in `pipe-pane` (log file) and as the `--remote-control` argument;
without the allowlist, shell code could be injected through it that would
run when the respective session ends.

In addition, `controller.sh` warns on every invocation if `sessions.conf`
is writable by other local users (`chmod 600` recommended) — whoever can
write that file can effectively run arbitrary shell code in every session.

## Operating sessions

```bash
./controller.sh status          # overview: running/stopped (all sessions)
./controller.sh status --json   # the same overview, machine-readable (e.g. monitoring)
./controller.sh list            # like status, but numbered + including archived
./controller.sh attach main     # attach (by name or number from "list")
# in tmux: Ctrl-b d              # detach, the session keeps running
./controller.sh stop            # stop all (SIGINT, then kill if necessary)
```

`status --json` returns `name`, `status`, `running`, `workdir`,
`fail_count` and `last_attempt_epoch` per session (the last two come from
the backoff state, see below — `fail_count` counts failed attempts **in a
row since the last success**, not a lifetime restart count).

`stop`/`archive`/`delete` automatically send **two** `C-c` 0.3s apart:
Claude Code does not exit after a single Ctrl-C (it only shows "Press
Ctrl-C again to exit" and needs the second one within ~1s, otherwise the
prompt resets). If you intervene manually via `attach` in a hanging
session, you must keep this in mind too — a single Ctrl-C is not enough
there.

## Renaming a session / changing config fields

```bash
./controller.sh rename 3 new-name
./controller.sh edit 3 --workdir /srv/repos/customer-b
./controller.sh edit 3 --resume last --extra-args "--permission-mode acceptEdits"
```

`rename` also works for a running session (it renames the tmux session and
the log/snapshot files, without data loss). `edit` only changes the fields
given and — like `unarchive` — takes effect only the next time that session
starts, not immediately on a running one.

Directly with tmux (same socket as the controller):

```bash
tmux -S ~/.local/state/claude-cli-controller/tmux.sock list-sessions
tmux -S ~/.local/state/claude-cli-controller/tmux.sock attach -t main
```

## Logs

Each session additionally pipes its tmux pane output into a log file:

```
~/.local/state/claude-cli-controller/logs/<name>.log
```

This file is the complete transcript, raw including ANSI escape codes
(hardly readable by hand) — it grows without bound, so set up `logrotate`
for permanent operation (see `docs/SETUP.md`, step 5).

In addition, the supervisor writes a readable plain-text snapshot of the
currently visible pane content for every running session on each tick
(`CLAUDE_CTRL_INTERVAL`, default 15s):

```
~/.local/state/claude-cli-controller/logs/<name>.snapshot.txt
```

This file is overwritten on every tick (no appending, no rotation needed) —
meant for a quick look ("what is this session doing right now"), not as a
complete record: output between two ticks can be missing (tmux scrollback
limit). For gapless traceability (e.g. "why did this session fail
repeatedly", see backoff below), `<name>.log` remains the authoritative
source.

## Removing a session permanently

Archiving (see above) is usually enough. If the entry should disappear
completely (not just stay archived):

```bash
./controller.sh delete 3              # stops + removes from sessions.conf
./controller.sh delete oldproject --purge-workdir   # additionally delete the working directory
```

Without `--purge-workdir`, the working directory (project files,
conversation history) is kept; only the controller entry disappears. With
`--purge-workdir` the directory is irrevocably deleted via `rm -rf` — meant
mainly for throwaway/test sessions, not for projects with real content.

**Guard rails:** If the workdir is outside `CLAUDE_CTRL_PROJECTS_DIR`
(default `~/projects`) — e.g. a project deliberately created externally via
`new <name> <own-path>` — `--purge-workdir` additionally requires
`--force`:

```bash
./controller.sh delete customer-b --purge-workdir --force
```

`--force` without `--purge-workdir`, as well as unknown options, are
rejected. `/` and `$HOME` are always refused, even with `--force`. This
protects against a typo in the `workdir` field of `sessions.conf` (e.g.
`/home/user` instead of `/home/user/x`) that would otherwise be executed
irrevocably via `rm -rf`.

## Backoff for repeatedly failing sessions

If a session keeps failing at startup (e.g. `--continue` without an
existing conversation, see above), `start`/`supervise` no longer retries on
every interval but with growing pauses: 15s → 30s → 60s → 120s → 300s →
900s (constant every 15min afterwards). From 5 failed attempts in a row on,
the session appears in `status`/`list` with a `[failed: N Versuche, zuletzt
vor Xs]` note. As soon as a start stays successful (the session still exists
at the next interval), the counter is reset. State per session:
`$STATE_DIR/backoff/<name>`.

## Backup & restore

```bash
./controller.sh backup                          # default target: $STATE_DIR/backups/claude-backup-<date>.tar.gz
./controller.sh backup /path/my-backup.tar.gz   # custom target

./controller.sh restore /path/my-backup.tar.gz --force
```

`backup` saves `config/sessions.conf`, `~/.claude.json` (trust state) and
`~/.claude/` (session transcripts, settings) as a `tar.gz` — intended for a
quick recovery after rebuilding the container. `restore` overwrites the
current state completely and therefore requires `--force`; stop running
sessions with `controller.sh stop` first, otherwise the state can become
inconsistent.

## Environment variables

See the table in the [README](../README.md#configuration-environment-variables).
