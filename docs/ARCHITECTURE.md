# Architektur

## Überblick

```
LXC-Container (Boot)
   └── systemd: claude-cli-controller.service
          └── controller.sh supervise
                 ├── tmux (Socket: ~/.local/state/claude-cli-controller/tmux.sock)
                 │      ├── Session "main"    -> claude (cwd: project-a)
                 │      ├── Session "support" -> claude --continue (cwd: project-b)
                 │      └── Session "sandbox" -> claude (cwd: scratch)
                 └── Watchdog-Loop (alle N Sekunden: fehlende Sessions neu starten)
```

## Warum tmux?

Claude Code ist primär eine interaktive REPL. Damit Sessions nach dem
Container-Boot ohne angemeldeten Benutzer weiterlaufen und trotzdem später
per SSH betretbar sind, läuft jede Session in einer eigenen **detached
tmux-Session**:

- Session bleibt aktiv, auch wenn niemand verbunden ist.
- Mehrere Personen/Tools können sich unabhängig per `tmux attach` anklinken.
- Ein eigener tmux-Socket (`tmux -S <sock>`) trennt die Controller-Sessions
  vom persönlichen `tmux` des Benutzers, falls dieser das Terminal auch
  interaktiv nutzt.

## Warum ein eigener Watchdog statt nur `Restart=on-failure`?

`systemd` überwacht nur den Hauptprozess des Service (`controller.sh
supervise`), nicht die einzelnen tmux-Panes/Claude-Prozesse darin. Stürzt
eine einzelne Claude-Session ab, würde systemd das nicht bemerken. Der
Supervisor-Loop in `controller.sh` prüft daher periodisch jede konfigurierte
Session und startet sie bei Bedarf neu — der systemd-Restart greift nur,
falls der Controller-Prozess selbst abstürzt.

## Komponenten

| Datei/Verzeichnis                          | Zweck                                      |
|---------------------------------------------|---------------------------------------------|
| `controller.sh`                             | Start/Stop/Status/Supervise-Logik           |
| `config/sessions.conf`                      | Welche Sessions mit welchen Optionen laufen |
| `systemd/claude-cli-controller.service`     | Autostart-Definition für den Container      |
| `~/.local/state/claude-cli-controller/`     | Laufzeitdaten: tmux-Socket, Logs pro Session|

## Nicht-Ziele (bewusst weggelassen)

- Kein eigenes Auth-/Secrets-Management: Claude Code nutzt die reguläre
  Login-Session (`~/.claude/`) bzw. `ANTHROPIC_API_KEY` des Benutzers, unter
  dem der Service läuft.
- Keine Web-UI/API — Zugriff erfolgt über SSH + `tmux attach` bzw.
  `controller.sh status/attach`.
- Keine Multi-Host-Orchestrierung — der Controller verwaltet Sessions nur
  innerhalb eines einzelnen LXC-Containers.
