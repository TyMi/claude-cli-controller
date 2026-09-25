#!/usr/bin/env bash
#
# claude-cli-controller
# Startet, überwacht und verwaltet mehrere Claude Code CLI Sessions in tmux.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CLAUDE_CTRL_CONFIG:-$SCRIPT_DIR/config/sessions.conf}"
STATE_DIR="${CLAUDE_CTRL_STATE_DIR:-$HOME/.local/state/claude-cli-controller}"
LOG_DIR="$STATE_DIR/logs"
TMUX_SOCK="$STATE_DIR/tmux.sock"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
SUPERVISE_INTERVAL="${CLAUDE_CTRL_INTERVAL:-15}"
PROJECTS_BASE_DIR="${CLAUDE_CTRL_PROJECTS_DIR:-$HOME/projects}"
CLAUDE_JSON="${CLAUDE_CTRL_CLAUDE_JSON:-$HOME/.claude.json}"
AUTO_TRUST="${CLAUDE_CTRL_AUTO_TRUST:-1}"
REMOTE_CONTROL="${CLAUDE_CTRL_REMOTE_CONTROL:-1}"

BACKOFF_DIR="$STATE_DIR/backoff"
# Backoff-Zeiten in Sekunden je Fehlversuch (Index = fail_count-1), letzter
# Wert wird bei weiteren Versuchen wiederholt (Deckel bei 15min).
BACKOFF_SCHEDULE=(15 30 60 120 300 900)
FAILED_THRESHOLD=5

mkdir -p "$STATE_DIR" "$LOG_DIR" "$BACKOFF_DIR"
# Logs enthalten die komplette Terminal-Ausgabe jeder Session (potenziell
# Secrets). "chmod" statt nur "mkdir -m", damit auch bereits vorhandene
# Verzeichnisse aus aelteren Versionen nachtraeglich abgesichert werden -
# ein Verzeichnis-Recht von 700 reicht aus, um andere lokale User vom
# Zugriff auf die Dateien darin auszuschliessen, unabhaengig von deren
# eigenem Modus. Robustheits-Review 2026-09-24, S6.
chmod 700 "$STATE_DIR" "$LOG_DIR" "$BACKOFF_DIR" 2>/dev/null || true

tmux_() { tmux -S "$TMUX_SOCK" "$@"; }

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }

# Reines Bash-Trimming (kein "echo | xargs"): xargs interpretiert
# Anführungszeichen selbst und bricht bei Werten wie "O'Briens-Projekt"
# mit "unmatched quote" ab, was unter set -e das ganze Skript beendet.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Nur unproblematische Zeichen erlauben (Buchstaben inkl. Umlaute per
# [:alpha:]/UTF-8-Locale, Ziffern, Leerzeichen, Bindestrich, Unterstrich).
# Blockiert insbesondere Anführungszeichen, Semikolon, $, Backtick,
# Backslash, /, |, &, <, >, (, ), {, }, # und ".". $name landet sonst
# ungefiltert in tmux-Kommandos (pipe-pane laeuft ueber eine Shell) und im
# Default-Pfad $PROJECTS_BASE_DIR/$name — siehe Security-Review 2026-09-24
# (S1: Shell-Injection, per PoC bestaetigt; zuendet verzoegert, sobald die
# betroffene Session/Pane endet).
# Zusaetzlich mindestens ein Buchstabe Pflicht: verhindert rein numerische
# Namen wie "2024", die "resolve_target" sonst immer als Listenindex statt
# als Namen interpretiert und dadurch nie per Namen ansprechbar waeren
# (Robustheits-Review 2026-09-24, B6).
valid_name() {
    local n="$1"
    [[ "$n" =~ ^[[:alpha:][:digit:]_-][[:alpha:][:digit:]\ _-]{0,63}$ ]] || return 1
    [[ "$n" =~ [[:alpha:]] ]]
}

# Backoff-Zustand pro Session: "$BACKOFF_DIR/<name>" enthaelt
# "fail_count;last_attempt_epoch". Verhindert, dass eine dauerhaft
# fehlschlagende Session (z.B. "--continue" ohne vorhandene Konversation,
# siehe docs/SESSIONS.md) den Supervisor in eine ungebremste
# Neustart-Schleife alle $SUPERVISE_INTERVAL Sekunden zwingt (Robustheits-
# Review 2026-09-24, B1).
backoff_file() { printf '%s/%s' "$BACKOFF_DIR" "$(printf '%s' "$1" | tr '/ ' '__')"; }
backoff_read() { local f; f="$(backoff_file "$1")"; [[ -f "$f" ]] && cat "$f" || echo "0;0"; }
backoff_write() { printf '%s;%s\n' "$2" "$3" > "$(backoff_file "$1")"; }
backoff_clear() { rm -f "$(backoff_file "$1")"; }
backoff_delay_for() {
    local idx=$(( $1 - 1 ))
    (( idx < 0 )) && idx=0
    (( idx >= ${#BACKOFF_SCHEDULE[@]} )) && idx=$((${#BACKOFF_SCHEDULE[@]} - 1))
    echo "${BACKOFF_SCHEDULE[$idx]}"
}

ensure_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        mkdir -p "$(dirname "$CONFIG_FILE")"
        cat > "$CONFIG_FILE" <<'HEADER'
# claude-cli-controller: Session-Definitionen
#
# Format: name;workdir;resume;extra_args;status
#   name        eindeutiger tmux-Session-Name
#   workdir     Arbeitsverzeichnis für "claude"
#   resume      leer=neu, "last"/"continue"=--continue, sonst=--resume <id>
#   extra_args  zusätzliche CLI-Flags
#   status      "active" (Standard) oder "archived" (wird bei start/supervise übersprungen)
HEADER
        log INFO "Neue Config angelegt: $CONFIG_FILE"
    fi
}

require_config() {
    [[ -f "$CONFIG_FILE" ]] || { log ERROR "Config nicht gefunden: $CONFIG_FILE (siehe: controller.sh new)"; exit 1; }
}

# Liest CONFIG_FILE EINMAL pro Skriptaufruf in parallele Arrays ein, statt
# dass jede der Lookup-Funktionen unten (frueher: each_session,
# session_defined, resolve_target, config_get_workdir, cmd_list) die Datei
# separat oeffnet und die Semikolon-Zeilen erneut parst. Ungueltige Namen
# werden hier zentral einmal gefiltert+geloggt statt in jeder Funktion
# einzeln. config_set_status/config_remove_entry/config_rename_entry/
# config_edit_entry schreiben die Datei weiterhin zeilenbasiert (erhalten
# Kommentare/Formatierung exakt) und setzen SESSIONS_LOADED=0, damit ein
# nachfolgender Aufruf hier neu einliest. Robustheits-Review 2026-09-24,
# O3 (zentrales Parsing) + O4 (Duplikat-Erkennung).
SESSION_NAMES=(); SESSION_WORKDIRS=(); SESSION_RESUMES=(); SESSION_EXTRAS=(); SESSION_STATUSES=()
SESSIONS_LOADED=0

load_sessions() {
    (( SESSIONS_LOADED )) && return 0
    SESSIONS_LOADED=1
    SESSION_NAMES=(); SESSION_WORKDIRS=(); SESSION_RESUMES=(); SESSION_EXTRAS=(); SESSION_STATUSES=()
    [[ -f "$CONFIG_FILE" ]] || return 0
    local name workdir resume extra status existing
    while IFS=';' read -r name workdir resume extra status || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(trim "$name")"
        workdir="$(trim "${workdir:-}")"
        resume="$(trim "${resume:-}")"
        extra="$(trim "${extra:-}")"
        status="$(trim "${status:-}")"
        [[ -z "$status" ]] && status="active"
        if ! valid_name "$name"; then
            log ERROR "[$name] ungueltiger Session-Name in $CONFIG_FILE (nur Buchstaben/Ziffern/Leerzeichen/-/_, mind. 1 Buchstabe), Zeile wird uebersprungen"
            continue
        fi
        for existing in "${SESSION_NAMES[@]}"; do
            if [[ "$existing" == "$name" ]]; then
                log WARN "[$name] mehrfach in $CONFIG_FILE definiert - weitere Definition wird ignoriert, erste gilt"
                continue 2
            fi
        done
        SESSION_NAMES+=("$name")
        SESSION_WORKDIRS+=("$workdir")
        SESSION_RESUMES+=("$resume")
        SESSION_EXTRAS+=("$extra")
        SESSION_STATUSES+=("$status")
    done < "$CONFIG_FILE"
}

# Ruft $1 (callback) je Session mit name workdir resume extra status auf.
each_session() {
    local callback="$1" i
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log WARN "Config nicht gefunden: $CONFIG_FILE — noch keine Sessions konfiguriert (siehe: controller.sh new)"
        return 0
    fi
    load_sessions
    for (( i=0; i<${#SESSION_NAMES[@]}; i++ )); do
        # "|| true": ein Fehler in einer einzelnen Session (z.B. fehlendes
        # workdir in start_one) darf unter set -e nicht die Verarbeitung
        # aller weiteren Sessions abbrechen. start_one loggt den Fehler
        # bereits selbst, bevor es return 1 liefert.
        "$callback" "${SESSION_NAMES[$i]}" "${SESSION_WORKDIRS[$i]}" "${SESSION_RESUMES[$i]}" "${SESSION_EXTRAS[$i]}" "${SESSION_STATUSES[$i]}" || true
    done
}

session_exists() { tmux_ has-session -t "=$1" 2>/dev/null; }

session_defined() {
    local target="$1" i
    load_sessions
    for (( i=0; i<${#SESSION_NAMES[@]}; i++ )); do
        [[ "${SESSION_NAMES[$i]}" == "$target" ]] && return 0
    done
    return 1
}

# Gibt zu einer Nummer (aus "list") den zugehörigen Session-Namen aus,
# oder den Namen unverändert zurück falls kein reiner Zahlenwert übergeben wurde.
resolve_target() {
    local arg="$1"
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        require_config
        load_sessions
        local idx=$((arg - 1))
        if (( idx < 0 || idx >= ${#SESSION_NAMES[@]} )); then
            log ERROR "Keine Session mit Nummer $arg (siehe: controller.sh list)"
            exit 1
        fi
        echo "${SESSION_NAMES[$idx]}"
    else
        echo "$arg"
    fi
}

# Schreibt für die Session $1 den Status-Wert $2 in die Config zurück,
# alle anderen Zeilen bleiben unverändert erhalten.
config_set_status() {
    local target="$1" newstatus="$2"
    require_config
    local tmpfile
    tmpfile="$(mktemp "${CONFIG_FILE}.XXXXXX")"
    local line name workdir resume extra status found=0
    while IFS='' read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            printf '%s\n' "$line" >> "$tmpfile"
            continue
        fi
        IFS=';' read -r name workdir resume extra status <<< "$line"
        if [[ "$(trim "$name")" == "$target" ]]; then
            printf '%s;%s;%s;%s;%s\n' \
                "$(trim "$name")" "$(trim "${workdir:-}")" "$(trim "${resume:-}")" "$(trim "${extra:-}")" "$newstatus" >> "$tmpfile"
            found=1
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$CONFIG_FILE"
    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmpfile"
        log ERROR "[$target] nicht in $CONFIG_FILE gefunden"
        exit 1
    fi
    mv "$tmpfile" "$CONFIG_FILE"
    SESSIONS_LOADED=0
}

# Gibt das Workdir-Feld der Session $1 aus sessions.conf zurück (leer,
# falls nicht gefunden).
config_get_workdir() {
    local target="$1" i
    load_sessions
    for (( i=0; i<${#SESSION_NAMES[@]}; i++ )); do
        [[ "${SESSION_NAMES[$i]}" == "$target" ]] && { echo "${SESSION_WORKDIRS[$i]}"; return 0; }
    done
}

# Entfernt die Zeile der Session $1 komplett aus sessions.conf (Gegenstück
# zu config_set_status, das die Zeile nur mit neuem Status umschreibt).
config_remove_entry() {
    local target="$1"
    require_config
    local tmpfile
    tmpfile="$(mktemp "${CONFIG_FILE}.XXXXXX")"
    local line name found=0
    while IFS='' read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            printf '%s\n' "$line" >> "$tmpfile"
            continue
        fi
        IFS=';' read -r name _ <<< "$line"
        if [[ "$(trim "$name")" == "$target" ]]; then
            found=1
            continue
        fi
        printf '%s\n' "$line" >> "$tmpfile"
    done < "$CONFIG_FILE"
    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmpfile"
        log ERROR "[$target] nicht in $CONFIG_FILE gefunden"
        exit 1
    fi
    mv "$tmpfile" "$CONFIG_FILE"
    SESSIONS_LOADED=0
}

# Benennt die Session $1 zu $2 um (Gegenstück zu config_set_status, aendert
# aber das Name-Feld statt Status). Fuer "rename" (F8).
config_rename_entry() {
    local target="$1" newname="$2"
    require_config
    local tmpfile
    tmpfile="$(mktemp "${CONFIG_FILE}.XXXXXX")"
    local line name workdir resume extra status found=0
    while IFS='' read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            printf '%s\n' "$line" >> "$tmpfile"
            continue
        fi
        IFS=';' read -r name workdir resume extra status <<< "$line"
        if [[ "$(trim "$name")" == "$target" ]]; then
            printf '%s;%s;%s;%s;%s\n' \
                "$newname" "$(trim "${workdir:-}")" "$(trim "${resume:-}")" "$(trim "${extra:-}")" "$(trim "${status:-}")" >> "$tmpfile"
            found=1
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$CONFIG_FILE"
    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmpfile"
        log ERROR "[$target] nicht in $CONFIG_FILE gefunden"
        exit 1
    fi
    mv "$tmpfile" "$CONFIG_FILE"
    SESSIONS_LOADED=0
}

# Aendert gezielt workdir/resume/extra_args der Session $1, je nachdem
# welches der set_*-Flags (0/1) gesetzt ist. Fuer "edit" (F8).
config_edit_entry() {
    local target="$1" set_workdir="$2" new_workdir="$3" set_resume="$4" new_resume="$5" set_extra="$6" new_extra="$7"
    require_config
    local tmpfile
    tmpfile="$(mktemp "${CONFIG_FILE}.XXXXXX")"
    local line name workdir resume extra status found=0
    while IFS='' read -r line || [[ -n "$line" ]]; do
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            printf '%s\n' "$line" >> "$tmpfile"
            continue
        fi
        IFS=';' read -r name workdir resume extra status <<< "$line"
        if [[ "$(trim "$name")" == "$target" ]]; then
            workdir="$(trim "${workdir:-}")"; resume="$(trim "${resume:-}")"; extra="$(trim "${extra:-}")"
            (( set_workdir )) && workdir="$new_workdir"
            (( set_resume )) && resume="$new_resume"
            (( set_extra )) && extra="$new_extra"
            printf '%s;%s;%s;%s;%s\n' "$(trim "$name")" "$workdir" "$resume" "$extra" "$(trim "${status:-}")" >> "$tmpfile"
            found=1
        else
            printf '%s\n' "$line" >> "$tmpfile"
        fi
    done < "$CONFIG_FILE"
    if [[ "$found" -eq 0 ]]; then
        rm -f "$tmpfile"
        log ERROR "[$target] nicht in $CONFIG_FILE gefunden"
        exit 1
    fi
    mv "$tmpfile" "$CONFIG_FILE"
    SESSIONS_LOADED=0
}

# Markiert $1 in ~/.claude.json als vertrauenswürdig (hasTrustDialogAccepted),
# damit "claude" beim ersten Start in einer unbeaufsichtigten tmux-Session
# nicht auf die interaktive Trust-Abfrage wartet. Nur für Projekte gedacht,
# die über "controller.sh new" selbst angelegt wurden. Abschaltbar über
# CLAUDE_CTRL_AUTO_TRUST=0.
trust_project_dir() {
    local dir="$1"
    [[ "$AUTO_TRUST" == "1" ]] || return 0
    if [[ ! -f "$CLAUDE_JSON" ]]; then
        log WARN "$CLAUDE_JSON nicht gefunden, überspringe Auto-Trust für $dir"
        return 0
    fi
    if ! CLAUDE_CTRL_TRUST_DIR="$dir" CLAUDE_CTRL_TRUST_FILE="$CLAUDE_JSON" python3 <<'PYEOF'
import json, os, sys

path = os.environ["CLAUDE_CTRL_TRUST_FILE"]
target = os.environ["CLAUDE_CTRL_TRUST_DIR"]

with open(path) as f:
    data = json.load(f)

projects = data.setdefault("projects", {})
entry = projects.setdefault(target, {})
entry.setdefault("allowedTools", [])
entry["hasTrustDialogAccepted"] = True

tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
PYEOF
    then
        log WARN "[$dir] konnte nicht automatisch als vertrauenswürdig markiert werden"
        return 0
    fi
    log INFO "[$dir] als vertrauenswürdig markiert (hasTrustDialogAccepted=true)"
}

build_cmd() {
    local name="$1" resume="$2" extra="$3"
    local cmd="$CLAUDE_BIN"
    case "$resume" in
        "") ;;
        last|continue) cmd="$cmd --continue" ;;
        *) cmd="$cmd --resume $resume" ;;
    esac
    [[ "$REMOTE_CONTROL" == "1" ]] && cmd="$cmd --remote-control $(printf '%q' "$name")"
    [[ -n "$extra" ]] && cmd="$cmd $extra"
    echo "$cmd"
}

start_one() {
    local name="$1" workdir="$2" resume="$3" extra="$4" status="${5:-active}"
    if [[ "$status" == "archived" ]]; then
        backoff_clear "$name"
        # Nur warnen, KEIN aktiver Stopp: eine Session, die z.B. durch
        # manuelles Editieren von sessions.conf (statt ueber "archive",
        # das explizit stoppt) als archived markiert wurde, aber noch
        # laeuft, bleibt bewusst unangetastet - ein automatischer Zwangs-
        # Stopp wuerde bei jedem Tick (SUPERVISE_INTERVAL) auch eine gerade
        # aktiv genutzte Session treffen koennen, z.B. durch einen blossen
        # Tippfehler beim Editieren. Passt zur Philosophie aus
        # session-lifecycle.md: Sessions werden nur ueber explizite
        # Aktionen gestoppt, nie automatisch im Hintergrund. Feature-
        # Analyse 2026-09-24/25, O5.
        if session_exists "$name"; then
            log WARN "[$name] ist als 'archived' markiert, laeuft aber noch - kein automatischer Stopp. Zum Stoppen: controller.sh archive $name"
        fi
        return 0
    fi
    if session_exists "$name"; then
        backoff_clear "$name"
        log INFO "[$name] läuft bereits, überspringe"
        return 0
    fi

    local fail_count last_attempt now
    IFS=';' read -r fail_count last_attempt <<< "$(backoff_read "$name")"
    now=$(date +%s)
    if (( fail_count > 0 )); then
        local delay; delay="$(backoff_delay_for "$fail_count")"
        if (( now - last_attempt < delay )); then
            # Noch in der Backoff-Pause: diesen Tick still uebergehen,
            # kein Log-Spam alle $SUPERVISE_INTERVAL Sekunden.
            return 0
        fi
    fi

    if [[ -n "$workdir" && ! -d "$workdir" ]]; then
        log ERROR "[$name] Arbeitsverzeichnis fehlt: $workdir"
        backoff_write "$name" "$((fail_count + 1))" "$now"
        return 1
    fi
    local cmd attempt=$((fail_count + 1))
    cmd="$(build_cmd "$name" "$resume" "$extra")"
    if (( attempt >= FAILED_THRESHOLD )); then
        log WARN "[$name] Versuch $attempt in Folge (Backoff aktiv, letzter Fehlversuch vor $((now - last_attempt))s)"
    fi
    log INFO "[$name] starte: $cmd (cwd=${workdir:-$HOME})"
    backoff_write "$name" "$attempt" "$now"
    tmux_ new-session -d -s "$name" -c "${workdir:-$HOME}" "$cmd"
    # Kein "-t =$name" hier: tmux' exaktes Match bricht bei pipe-pane
    # (anders als bei has-session) mit "can't find pane", sobald $name ein
    # Leerzeichen enthaelt (live getestet, tmux 3.4) — real vorkommende
    # Namen wie "CamDisplay Schützen" wuerden sonst nie geloggt. Die
    # eigentliche Injection wird bereits durch valid_name() verhindert;
    # printf %q auf den Logpfad bleibt als zusaetzliche Absicherung.
    tmux_ pipe-pane -t "$name" -o "cat >> $(printf '%q' "$LOG_DIR/$name.log")"
}

stop_one() {
    local name="$1"
    if ! session_exists "$name"; then
        log INFO "[$name] läuft nicht"
        return 0
    fi
    log INFO "[$name] stoppe (SIGINT, dann kill falls nötig)"
    tmux_ send-keys -t "$name" C-c || true
    sleep 2
    if session_exists "$name"; then
        tmux_ kill-session -t "$name" || true
    fi
}

status_one() {
    local name="$1" workdir="$2" resume="$3" extra="$4" status="$5"
    local running="stopped"
    session_exists "$name" && running="running"
    printf '  [%-8s] [%-8s] %-20s %s%s\n' "$status" "$running" "$name" "$workdir" "$(backoff_note "$name" "$running")"
}

# Haengt bei wiederholt fehlschlagenden Sessions einen Hinweis an (siehe
# start_one/backoff_*), sonst leer.
backoff_note() {
    local name="$1" running="$2"
    [[ "$running" == "stopped" ]] || return 0
    local fail_count last_attempt
    IFS=';' read -r fail_count last_attempt <<< "$(backoff_read "$name")"
    (( fail_count >= FAILED_THRESHOLD )) || return 0
    printf '  [failed: %s Versuche, zuletzt vor %ss]' "$fail_count" "$(( $(date +%s) - last_attempt ))"
}

# Schreibt einen lesbaren Klartext-Schnappschuss des aktuellen Pane-Inhalts
# nach "$LOG_DIR/<name>.snapshot.txt" (ueberschrieben, kein Anhaengen).
# Ergaenzt die vollstaendige, aber ANSI-verseuchte pipe-pane-Mitschrift in
# "<name>.log" um eine schnell lesbare Momentaufnahme fuer Menschen - ersetzt
# sie bewusst NICHT: periodische Snapshots koennten Ausgaben zwischen zwei
# Intervallen verpassen (Scrollback-Limit), was fuer Fehlerdiagnose (z.B.
# B1-Backoff: "warum scheitert die Session wiederholt?") die falsche Wahl
# waere. Wird vom Supervisor-Loop alle SUPERVISE_INTERVAL Sekunden fuer
# jede laufende Session aufgerufen. Robustheits-Review 2026-09-24, O1.
snapshot_one() {
    local name="$1"
    session_exists "$name" || return 0
    tmux_ capture-pane -p -t "$name" > "$LOG_DIR/$name.snapshot.txt" 2>/dev/null || true
}

cmd_start_all() { each_session start_one; }

# Stoppt alle Sessions PARALLEL (SIGINT an alle gleichzeitig, dann ein
# gemeinsames, zeitlich begrenztes Warten) statt seriell mit "sleep 2" pro
# Session wie stop_one — bei vielen Sessions sonst zu langsam fuer
# TimeoutStopSec der systemd-Unit, und der einzige Stop-Pfad (siehe
# cmd_supervise-Trap, ExecStop wurde bewusst aus der Unit entfernt) muss
# in jedem Fall darunter bleiben. Robustheits-Review 2026-09-24, B2.
cmd_stop_all() {
    load_sessions
    local i names=()
    for (( i=0; i<${#SESSION_NAMES[@]}; i++ )); do
        if session_exists "${SESSION_NAMES[$i]}"; then
            log INFO "[${SESSION_NAMES[$i]}] stoppe (SIGINT)"
            tmux_ send-keys -t "${SESSION_NAMES[$i]}" C-c || true
            names+=("${SESSION_NAMES[$i]}")
        fi
    done
    (( ${#names[@]} == 0 )) && return 0

    local waited=0 max_wait=10 still_running name
    while (( waited < max_wait )); do
        still_running=0
        for name in "${names[@]}"; do
            session_exists "$name" && still_running=1
        done
        (( still_running == 0 )) && break
        sleep 1
        waited=$((waited + 1))
    done

    for name in "${names[@]}"; do
        if session_exists "$name"; then
            log INFO "[$name] reagiert nicht, kill-session"
            tmux_ kill-session -t "$name" || true
        fi
    done
}

cmd_status_all() { echo "Claude CLI Sessions ($TMUX_SOCK):"; each_session status_one; }
cmd_restart_all() { cmd_stop_all; sleep 1; cmd_start_all; }

# Maschinenlesbare Variante von "status" fuer Monitoring (z.B. Home-
# Assistant Command-Line-Sensor). fail_count/last_attempt_epoch sind die
# vom Backoff getrackten Werte (siehe backoff_*) - "fail_count" zaehlt
# Fehlversuche IN FOLGE seit dem letzten Erfolg, nicht die Lifetime-Anzahl
# an Neustarts, um hier keine Zahl vorzutaeuschen, die tatsaechlich nicht
# getrackt wird. Feature-Vorschlag 2026-09-24, F1.
cmd_status_json() {
    load_sessions
    local i name status running fail_count last_attempt
    {
        for (( i=0; i<${#SESSION_NAMES[@]}; i++ )); do
            name="${SESSION_NAMES[$i]}"
            status="${SESSION_STATUSES[$i]}"
            running="stopped"
            session_exists "$name" && running="running"
            IFS=';' read -r fail_count last_attempt <<< "$(backoff_read "$name")"
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$status" "$running" "${SESSION_WORKDIRS[$i]}" "$fail_count" "$last_attempt"
        done
    } | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    name, status, running, workdir, fail_count, last_attempt = line.split("\t")
    fail_count = int(fail_count)
    out.append({
        "name": name,
        "status": status,
        "running": running == "running",
        "workdir": workdir,
        "fail_count": fail_count,
        "last_attempt_epoch": int(last_attempt) if fail_count > 0 else None,
    })
print(json.dumps(out, indent=2))
'
}

# Nummerierte Übersicht aller konfigurierten Sessions (auch archivierte),
# als Basis für "controller.sh archive/unarchive <nummer>".
cmd_list() {
    require_config
    load_sessions
    printf '%-3s %-9s %-9s %-20s %s\n' "Nr" "Status" "Läuft" "Name" "Workdir"
    local i running
    for (( i=0; i<${#SESSION_NAMES[@]}; i++ )); do
        running="stopped"
        session_exists "${SESSION_NAMES[$i]}" && running="running"
        printf '%-3s %-9s %-9s %-20s %s%s\n' "$((i+1))" "${SESSION_STATUSES[$i]}" "$running" "${SESSION_NAMES[$i]}" "${SESSION_WORKDIRS[$i]}" "$(backoff_note "${SESSION_NAMES[$i]}" "$running")"
    done
}

# Legt ein neues Projekt an: Verzeichnis erstellen, in sessions.conf
# eintragen und sofort starten.
cmd_new() {
    local name="${1:?Usage: controller.sh new <name> [workdir] [resume] [extra_args]}"
    local workdir="${2:-$PROJECTS_BASE_DIR/$name}"
    local resume="${3-last}"
    local extra="${4:-}"

    ensure_config
    if ! valid_name "$name"; then
        log ERROR "[$name] ungueltiger Session-Name (nur Buchstaben/Ziffern/Leerzeichen/-/_ erlaubt, max. 64 Zeichen)"
        exit 1
    fi
    if session_defined "$name"; then
        log ERROR "[$name] existiert bereits in $CONFIG_FILE"
        exit 1
    fi

    # Nur neu angelegte Verzeichnisse automatisch trusten (siehe
    # trust_project_dir) — ein bereits vorhandenes Verzeichnis (z.B. ein
    # fremdes Repo als explizites $workdir) soll den Trust-Dialog nicht
    # stillschweigend umgehen. Security-Review 2026-09-24 (S2).
    local created_workdir=0
    [[ -e "$workdir" ]] || created_workdir=1
    mkdir -p "$workdir"
    log INFO "[$name] Verzeichnis angelegt: $workdir"

    printf '%s;%s;%s;%s;active\n' "$name" "$workdir" "$resume" "$extra" >> "$CONFIG_FILE"
    log INFO "[$name] in $CONFIG_FILE eingetragen"

    if (( created_workdir )); then
        trust_project_dir "$workdir"
    else
        log WARN "[$name] Verzeichnis existierte bereits, Auto-Trust uebersprungen — Trust-Dialog ggf. manuell in 'controller.sh attach $name' bestaetigen"
    fi
    # Erststart: "$workdir" wurde soeben angelegt, es gibt also garantiert
    # noch keine Konversation. "claude --continue" bricht in diesem Fall
    # mit "No conversation found to continue" ab statt neu zu starten -
    # daher hier immer ohne resume starten. Ab dem zweiten Start (Restart/
    # Reboot) greift dann der in sessions.conf hinterlegte $resume-Wert.
    start_one "$name" "$workdir" "" "$extra" "active"
}

# Stoppt eine Session und markiert sie als archiviert, sodass start/supervise
# sie künftig überspringen (Eintrag bleibt zur Historie erhalten).
cmd_archive() {
    local target="${1:?Usage: controller.sh archive <nummer|name> (siehe: controller.sh list)}"
    local name; name="$(resolve_target "$target")"
    session_defined "$name" || { log ERROR "[$name] nicht in $CONFIG_FILE gefunden"; exit 1; }
    stop_one "$name"
    config_set_status "$name" "archived"
    log INFO "[$name] archiviert (gestoppt, wird bei start/supervise übersprungen)"
}

# Macht eine archivierte Session wieder startbar (startet sie nicht automatisch).
cmd_unarchive() {
    local target="${1:?Usage: controller.sh unarchive <nummer|name> (siehe: controller.sh list)}"
    local name; name="$(resolve_target "$target")"
    session_defined "$name" || { log ERROR "[$name] nicht in $CONFIG_FILE gefunden"; exit 1; }
    config_set_status "$name" "active"
    log INFO "[$name] reaktiviert (mit 'controller.sh start' wieder starten)"
}

# Entfernt eine Session vollständig aus sessions.conf (Gegenstück zu
# "archive", das den Eintrag zur Historie behält). Stoppt die Session
# vorher, falls sie noch läuft. Das Arbeitsverzeichnis bleibt standardmäßig
# erhalten (nur der Controller-Eintrag verschwindet) - erst mit
# --purge-workdir wird es zusätzlich unwiderruflich gelöscht.
cmd_delete() {
    local target="${1:?Usage: controller.sh delete <nummer|name> [--purge-workdir [--force]]}"
    local purge="${2:-}"
    local force="${3:-}"
    local name; name="$(resolve_target "$target")"
    session_defined "$name" || { log ERROR "[$name] nicht in $CONFIG_FILE gefunden"; exit 1; }

    local workdir
    workdir="$(config_get_workdir "$name")"

    stop_one "$name"
    config_remove_entry "$name"
    log INFO "[$name] aus $CONFIG_FILE entfernt"

    if [[ "$purge" == "--purge-workdir" ]]; then
        # Leitplanken gegen einen Tippfehler in sessions.conf's workdir-Feld
        # (z.B. workdir=/home/user statt .../home/user/x), der sonst
        # unwiderruflich per "rm -rf" ausgefuehrt wuerde. Security-Review
        # 2026-09-24, S5.
        local real_workdir=""
        [[ -n "$workdir" ]] && real_workdir="$(realpath -- "$workdir" 2>/dev/null || true)"
        if [[ -z "$real_workdir" || ! -d "$real_workdir" ]]; then
            log WARN "[$name] Workdir existiert nicht (mehr), nichts zu loeschen: ${workdir:-<leer>}"
        elif [[ "$real_workdir" == "/" || "$real_workdir" == "$HOME" ]]; then
            log ERROR "[$name] '$real_workdir' sieht nach einem kritischen Systempfad aus - Loeschen abgelehnt (auch mit --force)."
            exit 1
        else
            local real_base; real_base="$(realpath -- "$PROJECTS_BASE_DIR" 2>/dev/null || echo "$PROJECTS_BASE_DIR")"
            if [[ "$real_workdir" != "$real_base"/* && "$force" != "--force" ]]; then
                log ERROR "[$name] '$real_workdir' liegt ausserhalb von PROJECTS_BASE_DIR ('$real_base') - zur Sicherheit abgelehnt. Zum Erzwingen: controller.sh delete $target --purge-workdir --force"
                exit 1
            fi
            rm -rf -- "$real_workdir"
            log INFO "[$name] Arbeitsverzeichnis gelöscht: $real_workdir"
        fi
    elif [[ -n "$workdir" ]]; then
        log INFO "[$name] Arbeitsverzeichnis bleibt erhalten: $workdir (mit --purge-workdir zusätzlich löschen)"
    fi
}

# Benennt eine Session um: Config-Eintrag, laufende tmux-Session (falls
# aktiv) und die Log-/Snapshot-Dateien. Feature-Vorschlag 2026-09-24, F8.
cmd_rename() {
    local target="${1:?Usage: controller.sh rename <nr|name> <neuer-name>}"
    local new_name="${2:?Usage: controller.sh rename <nr|name> <neuer-name>}"
    local name; name="$(resolve_target "$target")"
    session_defined "$name" || { log ERROR "[$name] nicht in $CONFIG_FILE gefunden"; exit 1; }
    if ! valid_name "$new_name"; then
        log ERROR "[$new_name] ungueltiger Session-Name (nur Buchstaben/Ziffern/Leerzeichen/-/_, mind. 1 Buchstabe, max. 64 Zeichen)"
        exit 1
    fi
    if [[ "$new_name" == "$name" ]]; then
        log INFO "[$name] Name unveraendert"
        return 0
    fi
    session_defined "$new_name" && { log ERROR "[$new_name] existiert bereits in $CONFIG_FILE"; exit 1; }

    if session_exists "$name"; then
        # Laufenden Log-Pipe erst sauber schliessen (ohne "-o": schliesst
        # bestehenden Pipe statt einen zweiten zu oeffnen), sonst wuerde die
        # laufende "cat"-Instanz stur weiter unter dem ALTEN Dateinamen
        # schreiben (offener Dateideskriptor ueberlebt auch das "mv" unten,
        # aber ohne Pfad waere der Inhalt danach nicht mehr auffindbar).
        tmux_ pipe-pane -t "$name"
        tmux_ rename-session -t "$name" "$new_name"
    fi
    config_rename_entry "$name" "$new_name"
    log INFO "[$name] umbenannt zu [$new_name] in $CONFIG_FILE"

    [[ -f "$LOG_DIR/$name.log" ]] && mv -- "$LOG_DIR/$name.log" "$LOG_DIR/$new_name.log"
    [[ -f "$LOG_DIR/$name.snapshot.txt" ]] && mv -- "$LOG_DIR/$name.snapshot.txt" "$LOG_DIR/$new_name.snapshot.txt"
    backoff_clear "$name"

    if session_exists "$new_name"; then
        tmux_ pipe-pane -t "$new_name" -o "cat >> $(printf '%q' "$LOG_DIR/$new_name.log")"
    fi
}

# Aendert workdir/resume/extra_args einer bestehenden Session gezielt,
# ohne die restliche Zeile in sessions.conf anzufassen. Wirkt erst beim
# naechsten Start dieser Session (analog zu "unarchive": kein impliziter
# Neustart, um eine laufende Session nicht ueberraschend zu beenden).
# Feature-Vorschlag 2026-09-24, F8.
cmd_edit() {
    local target="${1:?Usage: controller.sh edit <nr|name> [--workdir <pfad>] [--resume <last|continue|id|''>] [--extra-args <flags>]}"
    shift
    local name; name="$(resolve_target "$target")"
    session_defined "$name" || { log ERROR "[$name] nicht in $CONFIG_FILE gefunden"; exit 1; }

    local new_workdir="" new_resume="" new_extra="" set_workdir=0 set_resume=0 set_extra=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --workdir)    new_workdir="${2:?--workdir braucht einen Wert}"; set_workdir=1; shift 2 ;;
            --resume)     new_resume="${2-}"; set_resume=1; shift 2 ;;
            --extra-args) new_extra="${2-}"; set_extra=1; shift 2 ;;
            *) log ERROR "Unbekannte Option: $1 (erlaubt: --workdir, --resume, --extra-args)"; exit 1 ;;
        esac
    done
    if (( ! set_workdir && ! set_resume && ! set_extra )); then
        log ERROR "Nichts zu aendern angegeben (siehe: controller.sh edit <nr|name> --workdir/--resume/--extra-args <wert>)"
        exit 1
    fi
    config_edit_entry "$name" "$set_workdir" "$new_workdir" "$set_resume" "$new_resume" "$set_extra" "$new_extra"
    log INFO "[$name] Config aktualisiert (wirkt erst beim naechsten Start dieser Session)"
}

cmd_attach() {
    local target="${1:?Usage: controller.sh attach <nummer|name>}"
    local name; name="$(resolve_target "$target")"
    session_exists "$name" || { log ERROR "[$name] läuft nicht"; exit 1; }
    exec tmux -S "$TMUX_SOCK" attach -t "$name"
}

cmd_supervise() {
    log INFO "Supervisor gestartet (Intervall: ${SUPERVISE_INTERVAL}s)"
    cmd_start_all
    trap 'log INFO "Supervisor beendet, stoppe Sessions"; cmd_stop_all; exit 0' TERM INT
    while true; do
        # "sleep X" allein blockiert die Trap-Verarbeitung in Bash bis zu X
        # Sekunden (Signal wird erst NACH dem Ende des Foreground-Kommandos
        # behandelt) — "sleep X & wait $!" reagiert dagegen sofort auf
        # TERM/INT, da wait beim Signal unterbrochen wird. Empirisch
        # bestaetigt (Robustheits-Review 2026-09-24, B2).
        sleep "$SUPERVISE_INTERVAL" & wait $!
        each_session start_one
        each_session snapshot_one
    done
}

# Sichert sessions.conf, ~/.claude.json und ~/.claude/ (Session-Transkripte,
# Settings, Trust-Zustand) als tar.gz - fuer eine schnelle Wiederherstellung
# nach einem Container-Neuaufbau. Feature-Vorschlag 2026-09-24, F9.
cmd_backup() {
    local dest="${1:-$STATE_DIR/backups/claude-backup-$(date +%Y%m%d-%H%M%S).tar.gz}"
    mkdir -p "$(dirname "$dest")"
    local sources=()
    [[ -f "$CONFIG_FILE" ]] && sources+=("$CONFIG_FILE")
    [[ -f "$CLAUDE_JSON" ]] && sources+=("$CLAUDE_JSON")
    [[ -d "$HOME/.claude" ]] && sources+=("$HOME/.claude")
    if (( ${#sources[@]} == 0 )); then
        log ERROR "Nichts zu sichern gefunden (weder $CONFIG_FILE, $CLAUDE_JSON noch $HOME/.claude vorhanden)"
        exit 1
    fi
    log INFO "Sichere: ${sources[*]}"
    tar -czf "$dest" "${sources[@]}"
    log INFO "Backup geschrieben: $dest ($(du -h "$dest" 2>/dev/null | cut -f1))"
}

# Gegenstueck zu "backup": stellt sessions.conf, ~/.claude.json und
# ~/.claude/ aus einer zuvor erstellten tar.gz wieder her. Ueberschreibt
# den aktuellen Stand - analog zum --force-Muster von "delete
# --purge-workdir" bewusst nicht interaktiv, sondern per explizitem Flag,
# damit es scriptbar bleibt und zum Rest des Tools passt.
cmd_restore() {
    local archive="${1:?Usage: controller.sh restore <backup-datei.tar.gz> --force}"
    local force="${2:-}"
    [[ -f "$archive" ]] || { log ERROR "Backup-Datei nicht gefunden: $archive"; exit 1; }
    if [[ "$force" != "--force" ]]; then
        log ERROR "Restore ueberschreibt $CONFIG_FILE, $CLAUDE_JSON und $HOME/.claude - zur Sicherheit ist --force noetig: controller.sh restore $archive --force"
        log ERROR "Laufende Sessions vorher stoppen (controller.sh stop), sonst evtl. inkonsistenter Zustand."
        exit 1
    fi
    tar -xzf "$archive" -C /
    log INFO "Restore aus $archive abgeschlossen."
}

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Sessions verwalten:
  start                  Alle aktiven Sessions starten (idempotent, überspringt archivierte)
  stop                   Alle Sessions stoppen
  restart                Stop + Start
  status [--json]        Status aller Sessions anzeigen (--json: maschinenlesbar, z.B. für Monitoring)
  list                   Nummerierte Übersicht aller Sessions (für archive/unarchive/attach)
  attach <nr|name>       An eine laufende Session anhängen (Ctrl-b d zum Lösen)
  supervise              Sessions starten und dauerhaft überwachen (für systemd)

Projekte verwalten:
  new <name> [workdir] [resume] [extra_args]
                         Neues Projekt anlegen: Verzeichnis erstellen (Default:
                         $PROJECTS_BASE_DIR/<name>), in sessions.conf eintragen, starten
  archive <nr|name>      Session stoppen und archivieren (kein Autostart mehr)
  unarchive <nr|name>    Archivierte Session wieder aktivieren (Start separat nötig)
  rename <nr|name> <neuer-name>
                         Session umbenennen (Config, laufende tmux-Session, Log-Dateien)
  edit <nr|name> [--workdir <pfad>] [--resume <wert>] [--extra-args <flags>]
                         Workdir/Resume/Extra-Args gezielt ändern, wirkt erst beim
                         nächsten Start dieser Session
  delete <nr|name> [--purge-workdir [--force]]
                         Session stoppen und Eintrag komplett aus sessions.conf
                         entfernen (nicht nur archivieren). Arbeitsverzeichnis
                         bleibt standardmäßig erhalten, --purge-workdir löscht
                         es zusätzlich unwiderruflich. Liegt das Workdir
                         außerhalb von PROJECTS_BASE_DIR, ist zusätzlich
                         --force nötig (Schutz vor Tippfehlern); "/" und
                         $HOME werden immer verweigert.

Backup:
  backup [ziel.tar.gz]   Sichert $CONFIG_FILE, $CLAUDE_JSON und ~/.claude/
                         (Default-Ziel: $STATE_DIR/backups/claude-backup-<datum>.tar.gz)
  restore <datei.tar.gz> --force
                         Stellt ein Backup wieder her (überschreibt aktuellen Stand)

Config: $CONFIG_FILE
State:  $STATE_DIR
EOF
}

main() {
    local command="${1:-}"
    shift || true
    case "$command" in
        start)      cmd_start_all ;;
        stop)       cmd_stop_all ;;
        restart)    cmd_restart_all ;;
        status)     [[ "${1:-}" == "--json" ]] && cmd_status_json || cmd_status_all ;;
        list)       cmd_list ;;
        attach)     cmd_attach "${1:-}" ;;
        supervise)  cmd_supervise ;;
        new)        cmd_new "$@" ;;
        archive)    cmd_archive "${1:-}" ;;
        unarchive)  cmd_unarchive "${1:-}" ;;
        rename)     cmd_rename "${1:-}" "${2:-}" ;;
        edit)       cmd_edit "$@" ;;
        delete)     cmd_delete "${1:-}" "${2:-}" "${3:-}" ;;
        backup)     cmd_backup "${1:-}" ;;
        restore)    cmd_restore "${1:-}" "${2:-}" ;;
        *)          usage; exit 1 ;;
    esac
}

main "$@"
