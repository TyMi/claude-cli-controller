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
erwartet wird: `attach`, `archive`, `unarchive`, `rename`, `edit`, `delete`.

## Session archivieren

Stoppt die Session und markiert sie in der Config als `archived`, sodass sie
bei `start`/`supervise` (und damit auch nach einem Container-Neustart) nicht
mehr automatisch gestartet wird. Der Eintrag bleibt erhalten.

```bash
./controller.sh list            # Nummer nachsehen
./controller.sh archive 3       # per Nummer
./controller.sh archive altprojekt   # oder per Name
```

Wird `status` stattdessen von Hand in `sessions.conf` auf `archived`
gesetzt (statt über diesen Befehl), wird eine noch laufende Session
**nicht** automatisch gestoppt — nur bei jedem `start`/`supervise`-Tick als
Warnung geloggt (`... ist als 'archived' markiert, läuft aber noch`).
Bewusst kein automatischer Zwangs-Stopp, um nicht durch einen bloßen
Tippfehler beim Editieren eine gerade aktiv genutzte Session zu beenden —
zum tatsächlichen Stoppen weiterhin `controller.sh archive` verwenden.

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
| `name`       | Eindeutiger tmux-Session-Name. Erlaubt: Buchstaben (inkl. Umlaute), Ziffern, Leerzeichen, `-`, `_`, max. 64 Zeichen, **mindestens ein Buchstabe** — `controller.sh new` lehnt alles andere ab, und Zeilen mit ungültigem Namen werden beim Einlesen übersprungen (siehe unten). Ein rein numerischer Name (z.B. `"2024"`) ist bewusst nicht erlaubt: `archive`/`unarchive`/`attach`/`delete` interpretieren eine Zahl immer als Listenindex aus `list`, nie als Namen — ein solcher Name wäre also nie per Namen ansprechbar gewesen |
| `workdir`    | Arbeitsverzeichnis, in dem `claude` gestartet wird. Leer = `$HOME`          |
| `resume`     | Leer = neue Session · `last`/`continue` = `--continue` · sonst = `--resume <id>` |
| `extra_args` | Zusätzliche CLI-Flags, z.B. `--permission-mode acceptEdits`                |
| `status`     | `active` (Standard, leer = active) oder `archived`                        |

Kommentarzeilen beginnen mit `#`, leere Zeilen werden ignoriert. Kein
Semikolon in den Feldern selbst (zerschießt die Feld-Ausrichtung). Taucht
derselbe Name mehrfach auf (z.B. durch manuelles Bearbeiten), gilt die
erste Definition, alle weiteren werden mit einer Warnung übersprungen.

**Sicherheitshinweis:** `resume` und `extra_args` landen unquotiert in dem
Kommandostring, den `tmux new-session` als Shell-Befehl ausführt. Diese
Felder sind also effektiv Shell-Code — dort gehören nur vertrauenswürdige,
selbst gepflegte Werte hinein, keine Eingaben aus nicht vertrauenswürdigen
Quellen. `name` wird dagegen per Zeichen-Allowlist validiert (siehe oben)
und zusätzlich sauber gequotet, da er auch in `pipe-pane` (Log-Datei) und
als `--remote-control`-Argument verwendet wird — ohne die Allowlist ließe
sich darüber Shell-Code einschleusen, der beim Enden der jeweiligen
Session ausgeführt wird (Details/PoC: Security-Review 2026-09-24).

## Sessions bedienen

```bash
./controller.sh status          # Übersicht: running/stopped (alle Sessions)
./controller.sh status --json   # dieselbe Übersicht maschinenlesbar (z.B. Monitoring)
./controller.sh list            # wie status, aber nummeriert + inkl. archived
./controller.sh attach main     # anhängen (per Name oder Nummer aus "list")
# in tmux: Ctrl-b d              # lösen, Session läuft weiter
./controller.sh stop            # alle stoppen (SIGINT, danach kill falls nötig)
```

`status --json` liefert pro Session `name`, `status`, `running`,
`workdir`, `fail_count` und `last_attempt_epoch` (die beiden letzten aus
dem Backoff-Zustand, siehe unten — `fail_count` zählt Fehlversuche **in
Folge seit dem letzten Erfolg**, keine Lifetime-Neustartzahl).

## Session umbenennen / Config-Felder ändern

```bash
./controller.sh rename 3 neuer-name
./controller.sh edit 3 --workdir /srv/repos/kunde-b
./controller.sh edit 3 --resume last --extra-args "--permission-mode acceptEdits"
```

`rename` funktioniert auch bei einer laufenden Session (benennt die
tmux-Session und die Log-/Snapshot-Dateien mit um, ohne Datenverlust).
`edit` ändert nur die angegebenen Felder und wirkt — wie `unarchive` —
erst beim nächsten Start dieser Session, nicht sofort auf eine laufende.

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

Diese Datei ist die vollständige Mitschrift, roh inklusive ANSI-
Escape-Codes (kaum von Hand lesbar) — wächst unbegrenzt, für Dauerbetrieb
`logrotate` einrichten (siehe `docs/TROUBLESHOOTING.md`).

Zusätzlich schreibt der Supervisor bei jedem Tick (`SUPERVISE_INTERVAL`,
Default 15s) für jede laufende Session einen lesbaren Klartext-
Schnappschuss des aktuell sichtbaren Pane-Inhalts:

```
~/.local/state/claude-cli-controller/logs/<name>.snapshot.txt
```

Diese Datei wird bei jedem Tick überschrieben (kein Anhängen, keine
Rotation nötig) — gedacht für einen schnellen Blick ("was macht diese
Session gerade"), nicht als vollständiges Protokoll: Ausgaben zwischen
zwei Ticks können fehlen (tmux-Scrollback-Limit). Für lückenlose
Nachvollziehbarkeit (z.B. "warum ist diese Session wiederholt
gescheitert", siehe Backoff unten) bleibt `<name>.log` die maßgebliche
Quelle.

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

**Leitplanken:** Liegt das Workdir außerhalb von `PROJECTS_BASE_DIR`
(Default `~/projects`) — z.B. ein per `new <name> <eigener-pfad>` bewusst
extern angelegtes Projekt — verlangt `--purge-workdir` zusätzlich
`--force`:
```bash
./controller.sh delete kunde-b --purge-workdir --force
```
`/` und `$HOME` werden immer verweigert, auch mit `--force`. Das schützt
vor einem Tippfehler im `workdir`-Feld von `sessions.conf` (z.B.
`/home/user` statt `/home/user/x`), der sonst unwiderruflich per `rm -rf`
ausgeführt würde.

## Backoff bei wiederholt fehlschlagenden Sessions

Scheitert eine Session beim Start dauerhaft (z.B. `--continue` ohne
vorhandene Konversation, siehe oben), versucht `start`/`supervise` es
nicht mehr bei jedem Intervall erneut, sondern mit steigenden Pausen:
15s → 30s → 60s → 120s → 300s → 900s (danach konstant alle 15min). Ab 5
Fehlversuchen in Folge erscheint die Session in `status`/`list` mit einem
`[failed: N Versuche, zuletzt vor Xs]`-Hinweis. Sobald ein Start
erfolgreich bleibt (Session existiert beim nächsten Intervall noch),
wird der Zähler zurückgesetzt. Zustand pro Session:
`$STATE_DIR/backoff/<name>`.

## Backup & Restore

```bash
./controller.sh backup                          # Default-Ziel: $STATE_DIR/backups/claude-backup-<datum>.tar.gz
./controller.sh backup /pfad/mein-backup.tar.gz  # eigenes Ziel

./controller.sh restore /pfad/mein-backup.tar.gz --force
```

`backup` sichert `config/sessions.conf`, `~/.claude.json` (Trust-Zustand)
und `~/.claude/` (Session-Transkripte, Settings) als `tar.gz` — gedacht
für eine schnelle Wiederherstellung nach einem Container-Neuaufbau.
`restore` überschreibt den aktuellen Stand vollständig und verlangt
deshalb `--force`; laufende Sessions vorher mit `controller.sh stop`
beenden, sonst kann der Zustand inkonsistent werden.
