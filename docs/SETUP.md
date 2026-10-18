# Setup: LXC container + systemd

## Prerequisites in the container

```bash
sudo apt update
sudo apt install -y tmux python3
```

`python3` is needed by `trust_project_dir` (auto-trust for newly created
projects, see `docs/SESSIONS.md`) and by `status --json`, not just `tmux`.

The Claude Code CLI must be installed and **logged in** for the user the
service runs as (called `<user>` below — replace it consistently with the
actual user name):

```bash
# as <user>:
claude login
# or, alternatively, an API key instead of an interactive login (for the
# service, use the EnvironmentFile variant in step 3 - do NOT put
# "Environment=ANTHROPIC_API_KEY=..." directly into the unit, it would be
# readable via "systemctl show" by every local user on the host):
export ANTHROPIC_API_KEY=...
```

> Important: the systemd service runs without an interactive login shell.
> Make sure `claude` also works **without** a manually loaded `~/.bashrc`,
> e.g. by having the path to `claude` in the service's `PATH` or by setting
> an absolute path via `CLAUDE_BIN` in the unit file.

## 1. Get the project into the container

```bash
# e.g. via git clone, scp, or developed directly in the container:
cd /home/<user>/claude-cli-controller
```

Then either let `controller.sh new <name>` create `config/sessions.conf` on
first use (recommended), or start from the example:

```bash
cp config/sessions.conf.example config/sessions.conf
$EDITOR config/sessions.conf
chmod 600 config/sessions.conf   # the file is effectively shell code, see docs/SESSIONS.md
```

## 2. Test manually (before systemd takes over)

```bash
./controller.sh start
./controller.sh status
./controller.sh attach main
# Ctrl-b d detaches (the session keeps running)
./controller.sh stop
```

## 3. Install the systemd service

The unit file `systemd/claude-cli-controller.service` contains placeholders
(`<user>`, paths) for the user name and install path — replace them with the
actual values before copying, then:

```bash
sudo cp systemd/claude-cli-controller.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now claude-cli-controller.service
```

**Only if you use an API key instead of `claude login`:** the unit
optionally reads `/etc/claude-cli-controller.env` (`EnvironmentFile=-`, does
not fail if the file does not exist). Create the file with restricted
permissions and **do not** write the key directly as an `Environment=` line
into the unit (it would be readable by every local user via `systemctl
show`):

```bash
sudo install -m 600 -o <user> -g <user> /dev/null /etc/claude-cli-controller.env
echo 'ANTHROPIC_API_KEY=sk-...' | sudo tee /etc/claude-cli-controller.env >/dev/null
sudo systemctl restart claude-cli-controller.service
```

Check status/logs:

```bash
systemctl status claude-cli-controller.service
journalctl -u claude-cli-controller.service -f
```

The service runs `controller.sh supervise`: it starts all sessions at boot
and keeps them alive afterwards (see `docs/ARCHITECTURE.md`).

## 4. Make sure the LXC container autostarts

The container itself must start when the host boots (Proxmox/LXC
configuration outside this project):

```bash
# on the Proxmox host:
pct set <CTID> -onboot 1
```

Once the container boots, systemd inside it starts
`claude-cli-controller.service` automatically — provided it was activated
with `enable` (step 3).

## 5. Set up log rotation (required for permanent operation)

The `pipe-pane` transcripts under `.../logs/*.log` grow without bound (see
`docs/SESSIONS.md`). A ready-made config is included (replace the `<user>`
placeholder first):

```bash
sudo cp logrotate/claude-cli-controller.conf /etc/logrotate.d/claude-cli-controller
sudo sed -i 's#<user>#YOUR-USER#g' /etc/logrotate.d/claude-cli-controller
```

## 6. Bash completion (optional)

```bash
echo 'source /home/<user>/claude-cli-controller/completions/claude-cli-controller.bash' >> ~/.bashrc
```

Completes subcommands and (by number from `list`) the session reference for
`attach`/`archive`/`unarchive`/`rename`/`edit`/`delete`.

## 7. After config changes

A running supervisor re-reads `sessions.conf` on every tick
(`CLAUDE_CTRL_INTERVAL`, default 15s): new, archived and unarchived sessions
are picked up automatically, no service restart is needed.

Changes to a session that is **already running** (`edit`, or manual edits of
its line) only apply the next time that session starts, because running
sessions are never restarted implicitly:

```bash
./controller.sh stop      # or archive/unarchive as needed
./controller.sh start     # or: sudo systemctl restart claude-cli-controller.service
```

Changes to the unit file or environment file need
`sudo systemctl daemon-reload && sudo systemctl restart claude-cli-controller.service`.
