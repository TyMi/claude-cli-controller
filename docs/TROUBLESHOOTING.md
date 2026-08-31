# Troubleshooting

## Service startet, aber keine Session läuft

```bash
journalctl -u claude-cli-controller.service -e
```

Häufige Ursachen:

- `claude` nicht im `PATH` des Service-Environments. Fix: absoluten Pfad in
  `CLAUDE_BIN` setzen (Environment-Zeile in der `.service`-Datei) oder
  `PATH=` explizit in der Unit ergänzen.
- `tmux` nicht installiert (`sudo apt install tmux`).
- `workdir` aus `sessions.conf` existiert nicht → Fehler in den Logs unter
  `~/.local/state/claude-cli-controller/logs/`.

## "claude: command not found" nur unter systemd, manuell funktioniert es

systemd-Services erben nicht automatisch `~/.bashrc`/`~/.profile`. Prüfen wo
`claude` liegt (`which claude` als `<user>`) und den Pfad explizit in der
Unit setzen, z.B.:

```ini
Environment=PATH=/home/<user>/.local/bin:/usr/local/bin:/usr/bin:/bin
```

## Claude fragt nach Login / Authentifizierung

Der Service läuft als `<user>` ohne interaktives Terminal. Login muss
vorher einmalig interaktiv als `<user>` erfolgen (`claude login`), oder es
wird ein `ANTHROPIC_API_KEY` per `Environment=` in der Unit-Datei gesetzt.

## Session hängt am "Trust this folder?"-Dialog

Betrifft nur Sessions, die nicht über `controller.sh new` angelegt wurden
(z.B. manuell in `sessions.conf` eingetragen) — `new` markiert das
Verzeichnis automatisch als vertrauenswürdig. Fix:

```bash
python3 - <<'PYEOF'
import json, os
path = os.path.expanduser("~/.claude.json")
target = "/absoluter/pfad/zum/projekt"   # anpassen
with open(path) as f:
    data = json.load(f)
entry = data.setdefault("projects", {}).setdefault(target, {})
entry.setdefault("allowedTools", [])
entry["hasTrustDialogAccepted"] = True
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
os.replace(tmp, path)
PYEOF

tmux -S ~/.local/state/claude-cli-controller/tmux.sock kill-session -t <name>
./controller.sh start
```

## Session hängt / reagiert nicht mehr

```bash
./controller.sh attach <name>
# prüfen, ggf. Ctrl-c, dann Ctrl-b d zum Lösen
```

Wenn das nicht hilft:

```bash
tmux -S ~/.local/state/claude-cli-controller/tmux.sock kill-session -t <name>
./controller.sh start
```

## Log-Dateien wachsen unbegrenzt

`logrotate`-Konfiguration ergänzen, z.B. unter
`/etc/logrotate.d/claude-cli-controller`:

```
/home/<user>/.local/state/claude-cli-controller/logs/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
```

`copytruncate` ist hier notwendig, da tmux `pipe-pane` die Datei offen hält.

## Nach Neustart verbindet sich die Desktop App zu einer neuen, leeren Session

Remote Control war aktiv, aber die Desktop App zeigt keine bisherige
Konversation, sondern startet leer. Ursache: `resume` ist in
`sessions.conf` leer, daher startet `claude` bei jedem `start`/`supervise`
(also auch nach Container-/Host-Neustart) eine **neue** Konversation —
`--remote-control` aktiviert dann nur Remote Control für diese neue,
leere Session. Die alte Konversation bleibt zwar erhalten, ist aber nicht
mehr die, mit der sich Remote Control verbindet.

Fix: `resume` auf `last` setzen, damit `build_cmd` stattdessen
`claude --continue --remote-control <name>` baut (siehe
`docs/SESSIONS.md`):

```
main;/home/<user>/projects/project-a;last;;active
```

Wirkt erst beim nächsten Neustart der jeweiligen Session — laufende
Sessions werden von `start_one` übersprungen (`session_exists`), daher
ggf. einmalig `./controller.sh restart` bzw. die betroffene Session neu
starten, um die geänderte Config zu übernehmen.

## Container-Neustart bringt Sessions nicht wieder hoch

- Prüfen, ob der Service aktiviert ist: `systemctl is-enabled claude-cli-controller.service`
- Prüfen, ob der LXC-Container selbst `onboot: 1` hat (Host-seitig,
  außerhalb dieses Projekts).
