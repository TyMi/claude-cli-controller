# Setup: LXC-Container + systemd

## Voraussetzungen im Container

```bash
sudo apt update
sudo apt install -y tmux
```

Claude Code CLI muss für den Benutzer installiert und **eingeloggt** sein,
unter dem der Service läuft (im Folgenden `<user>` genannt — ersetze das
durchgängig durch den tatsächlichen Benutzernamen):

```bash
# als <user>:
claude login
# oder alternativ per API-Key statt interaktivem Login:
export ANTHROPIC_API_KEY=...   # dauerhaft z.B. in ~/.bashrc oder als
                                # systemd Environment= Zeile (siehe unten)
```

> Wichtig: Der systemd-Service läuft ohne interaktives Login-Shell. Prüfe,
> dass `claude` auch **ohne** manuell geladenes `~/.bashrc` funktioniert,
> z.B. Pfad zu `claude` in `PATH` des Service oder absoluter Pfad via
> `CLAUDE_BIN` in der Unit-Datei.

## 1. Projekt auf den Container bringen

```bash
# z.B. per git clone, scp, oder direkt im Container entwickelt:
cd /home/<user>/claude-cli-controller
cp config/sessions.conf.example config/sessions.conf
$EDITOR config/sessions.conf
```

## 2. Manuell testen (bevor systemd übernimmt)

```bash
./controller.sh start
./controller.sh status
./controller.sh attach main
# Ctrl-b d zum Lösen (Session bleibt aktiv)
./controller.sh stop
```

## 3. systemd-Service installieren

Die Unit-Datei liegt unter `systemd/claude-cli-controller.service` und
enthält Platzhalter (`<user>`, Pfad) für Benutzername und Installationspfad
— vor dem Kopieren durch die tatsächlichen Werte ersetzen, dann:

```bash
sudo cp systemd/claude-cli-controller.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now claude-cli-controller.service
```

Status/Logs prüfen:

```bash
systemctl status claude-cli-controller.service
journalctl -u claude-cli-controller.service -f
```

Der Service ruft `controller.sh supervise` auf: startet beim Boot alle
Sessions und hält sie danach am Leben (siehe `docs/ARCHITECTURE.md`).

## 4. LXC-Autostart sicherstellen

Der Container selbst muss beim Host-Boot starten (Proxmox/LXC-Konfiguration
außerhalb dieses Projekts):

```bash
# auf dem Proxmox-Host:
pct set <CTID> -onboot 1
```

Sobald der Container bootet, startet systemd innerhalb des Containers den
`claude-cli-controller.service` automatisch — vorausgesetzt er wurde mit
`enable` aktiviert (Schritt 3).

## 5. Nach Config-Änderungen

```bash
sudo systemctl restart claude-cli-controller.service
# oder ohne systemd-Neustart, nur neue/geänderte Sessions:
./controller.sh start
```
