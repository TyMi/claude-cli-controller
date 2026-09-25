# claude-cli-controller

![Built with AI](https://img.shields.io/badge/Built_with-AI-success)
[![CI](https://github.com/TyMi/claude-cli-controller/actions/workflows/ci.yml/badge.svg)](https://github.com/TyMi/claude-cli-controller/actions/workflows/ci.yml)

Startet, überwacht und verwaltet mehrere Claude Code CLI Sessions zentral in
einem LXC-Container. Jede Session läuft als detached `tmux`-Session; ein
systemd-Service startet beim Boot des Containers alle konfigurierten
Sessions automatisch und überwacht sie danach fortlaufend.

## Quick Start

```bash
# 1. Neues Projekt anlegen: Verzeichnis erstellen, eintragen, starten
./controller.sh new mein-projekt

# 2. Übersicht & Bedienung
./controller.sh list           # nummerierte Übersicht aller Sessions
./controller.sh attach mein-projekt   # oder per Nummer: attach 1
# in tmux: Ctrl-b d zum Lösen (Session läuft weiter)

# 3. Session archivieren (stoppen, kein Autostart mehr)
./controller.sh archive mein-projekt  # oder per Nummer: archive 1

# 4. Als systemd-Service dauerhaft einrichten -> siehe docs/SETUP.md
```

## Kommandos

| Befehl                        | Wirkung                                                        |
|--------------------------------|-----------------------------------------------------------------|
| `controller.sh new <name>`     | Projekt-Verzeichnis anlegen, in Config eintragen, sofort starten |
| `controller.sh list`           | Nummerierte Übersicht aller Sessions (inkl. archivierte)         |
| `controller.sh attach <nr\|name>` | An Session anhängen                                         |
| `controller.sh archive <nr\|name>` | Session stoppen und archivieren (kein Autostart mehr)      |
| `controller.sh unarchive <nr\|name>` | Archivierte Session wieder aktivieren                    |
| `controller.sh rename <nr\|name> <neuer-name>` | Session umbenennen                              |
| `controller.sh edit <nr\|name> [--workdir ...] [--resume ...] [--extra-args ...]` | Config-Felder ändern |
| `controller.sh delete <nr\|name> [--purge-workdir [--force]]` | Session entfernen, optional inkl. Verzeichnis |
| `controller.sh start`          | Alle aktiven Sessions starten (idempotent, überspringt archivierte) |
| `controller.sh stop`           | Alle Sessions stoppen                                            |
| `controller.sh restart`        | Stop + Start                                                     |
| `controller.sh status [--json]` | Laufende/gestoppte Sessions anzeigen (optional maschinenlesbar) |
| `controller.sh supervise`      | Start + Endlos-Watchdog (Einstiegspunkt für systemd)             |
| `controller.sh backup [ziel]` / `restore <datei> --force` | Konfiguration + `~/.claude/` sichern/wiederherstellen |

## Tests

```bash
sudo apt-get install -y shellcheck bats tmux python3
shellcheck controller.sh
bats test/controller.bats
```

Läuft bei jedem Push/PR automatisch via GitHub Actions (siehe Badge oben) —
für dieses öffentliche Repo ohne Minutenlimit/Kosten. `test/controller.bats`
deckt die im Zuge der Reviews vom 2026-09-24/25 gefundenen und gefixten
Probleme als dauerhafte Regressionstests ab (u.a. S1 Shell-Injection, B1
Backoff, S5 Purge-Leitplanken, S4 resume-Validierung).

## Dokumentation

- [Architektur](docs/ARCHITECTURE.md) — Wie die Komponenten zusammenspielen
- [Setup](docs/SETUP.md) — LXC-Container + systemd-Einrichtung Schritt für Schritt
- [Sessions](docs/SESSIONS.md) — Config-Format, Resume-Verhalten, Logs
- [Troubleshooting](docs/TROUBLESHOOTING.md) — Bekannte Probleme und Lösungen

## Lizenz

[MIT](LICENSE)
