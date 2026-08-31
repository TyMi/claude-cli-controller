# Sessions & Projekte verwalten

## Neues Projekt anlegen (empfohlener Weg)

```bash
./controller.sh new <name> [workdir] [resume] [extra_args]
```

Das erledigt in einem Schritt:

1. Legt `workdir` an (Standard: `$CLAUDE_CTRL_PROJECTS_DIR/<name>`, per
   Default `~/projects/<name>`), falls es noch nicht existiert.
2. Trägt die Session in `config/sessions.conf` ein (Status `active`).
3. Startet die Session sofort in tmux.

Jede gestartete Session läuft mit `--remote-control <name>`, damit sie in
der Remote-Control-/Fleet-Übersicht (z.B. `claude.ai/code`, andere lokale
Sessions via `ListAgents`) sichtbar und von dort aus bedienbar ist.
Abschaltbar per `CLAUDE_CTRL_REMOTE_CONTROL=0`.

Wird `resume` weggelassen, setzt `new` automatisch `last` (`--continue`),
damit die Session auch einen Container-/Host-Neustart übersteht, ohne den
Gesprächskontext zu verlieren (siehe `docs/TROUBLESHOOTING.md`, Abschnitt
"Nach Neustart verbindet sich die Desktop App zu einer neuen, leeren
Session"). Wer stattdessen bei jedem Start bewusst eine leere Session will
(z.B. ein Sandbox-Projekt), muss `resume` explizit als leeren String
übergeben (dritter Parameter `""`, nicht weglassen).

Der allererste Start durch `new` läuft dabei immer **ohne** `--continue`,
unabhängig vom `resume`-Wert: `workdir` wurde gerade erst angelegt, es gibt
also noch keine Konversation, und `claude --continue` bricht ohne
vorhandene Konversation mit `"No conversation found to continue"` sofort ab
statt neu zu starten. In `sessions.conf` wird trotzdem `last` hinterlegt,
sodass ab dem zweiten Start (Restart/Reboot) — wenn dank des Erststarts
bereits eine Konversation existiert — normal fortgesetzt wird.

`new` markiert das Verzeichnis dabei automatisch in `~/.claude.json` als
vertrauenswürdig (`hasTrustDialogAccepted=true`). Ohne das würde `claude`
in der unbeaufsichtigten tmux-Session am interaktiven Trust-Prompt hängen,
da niemand da ist, um ihn zu bestätigen. Das gilt nur für Verzeichnisse, die
`controller.sh` selbst anlegt — abschaltbar per `CLAUDE_CTRL_AUTO_TRUST=0`
(dann muss der Trust-Dialog einmalig per `controller.sh attach` manuell
bestätigt werden).

Beispiele:

```bash
# einfachstes Projekt, Verzeichnis wird automatisch unter ~/projects/kunde-a angelegt
# resume wird weggelassen -> automatisch "last" (übersteht Neustarts)
./controller.sh new kunde-a

# eigenes Arbeitsverzeichnis vorgeben
./controller.sh new kunde-b /srv/repos/kunde-b

# mit Zusatz-Flags, resume explizit leer -> startet bei jedem Neustart neu (z.B. Sandbox)
./controller.sh new kunde-c "" "" "--permission-mode acceptEdits"
```

## Sessions auflisten (nummeriert)

```bash
./controller.sh list
```

```
Nr  Status    Läuft    Name                 Workdir
1   active    running  main                 /home/<user>/projects/project-a
2   active    stopped  support              /home/<user>/projects/project-b
3   archived  stopped  altprojekt           /home/<user>/projects/altprojekt
```

Die Nummer bezieht sich auf die Reihenfolge in `sessions.conf` (Kommentare
zählen nicht mit) und kann überall dort verwendet werden, wo auch ein Name
erwartet wird: `attach`, `archive`, `unarchive`.

## Session archivieren

Stoppt die Session und markiert sie in der Config als `archived`, sodass sie
bei `start`/`supervise` (und damit auch nach einem Container-Neustart) nicht
mehr automatisch gestartet wird. Der Eintrag bleibt erhalten.

```bash
./controller.sh list            # Nummer nachsehen
./controller.sh archive 3       # per Nummer
./controller.sh archive altprojekt   # oder per Name
```

## Session reaktivieren

```bash
./controller.sh unarchive 3
./controller.sh start           # danach explizit wieder starten
```

## Format von `config/sessions.conf`

Wird normalerweise nicht von Hand gepflegt (siehe `new`/`archive` oben),
aber zur Referenz:

```
name;workdir;resume;extra_args;status
```

| Feld         | Bedeutung                                                                 |
|--------------|-----------------------------------------------------------------------------|
| `name`       | Eindeutiger tmux-Session-Name                                              |
| `workdir`    | Arbeitsverzeichnis, in dem `claude` gestartet wird. Leer = `$HOME`          |
| `resume`     | Leer = neue Session · `last`/`continue` = `--continue` · sonst = `--resume <id>` |
| `extra_args` | Zusätzliche CLI-Flags, z.B. `--permission-mode acceptEdits`                |
| `status`     | `active` (Standard, leer = active) oder `archived`                        |

Kommentarzeilen beginnen mit `#`, leere Zeilen werden ignoriert.

## Sessions bedienen

```bash
./controller.sh status          # Übersicht: running/stopped (alle Sessions)
./controller.sh list            # wie status, aber nummeriert + inkl. archived
./controller.sh attach main     # anhängen (per Name oder Nummer aus "list")
# in tmux: Ctrl-b d              # lösen, Session läuft weiter
./controller.sh stop            # alle stoppen (SIGINT, danach kill falls nötig)
```

Direkt mit tmux (gleicher Socket wie der Controller):

```bash
tmux -S ~/.local/state/claude-cli-controller/tmux.sock list-sessions
tmux -S ~/.local/state/claude-cli-controller/tmux.sock attach -t main
```

## Logs

Jede Session pipet ihre tmux-Pane-Ausgabe zusätzlich in eine Log-Datei:

```
~/.local/state/claude-cli-controller/logs/<name>.log
```

Diese Dateien wachsen unbegrenzt — für Dauerbetrieb `logrotate` einrichten
(siehe `docs/TROUBLESHOOTING.md`).

## Session dauerhaft entfernen

Archivieren (siehe oben) reicht in der Regel aus. Soll der Eintrag komplett
verschwinden (nicht nur archiviert bleiben):

```bash
./controller.sh delete 3              # stoppt + entfernt aus sessions.conf
./controller.sh delete altprojekt --purge-workdir   # zusätzlich Arbeitsverzeichnis löschen
```

Ohne `--purge-workdir` bleibt das Arbeitsverzeichnis (Projektdateien,
Konversationsverlauf) erhalten, nur der Controller-Eintrag verschwindet.
Mit `--purge-workdir` wird das Verzeichnis unwiderruflich per `rm -rf`
gelöscht — vor allem für Wegwerf-/Test-Sessions gedacht, nicht für Projekte
mit echtem Inhalt.
