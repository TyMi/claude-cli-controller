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

mkdir -p "$STATE_DIR" "$LOG_DIR"

tmux_() { tmux -S "$TMUX_SOCK" "$@"; }

log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"; }

trim() { echo "$1" | xargs; }

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

# Liest sessions.conf und ruft $1 (callback) je Session-Zeile mit
# name workdir resume extra status auf. Kommentare/Leerzeilen werden übersprungen.
# Fehlt die Config-Datei (z.B. direkt nach der Installation), wird das nur
# geloggt statt den Aufrufer (insb. "supervise") hart abbrechen zu lassen.
each_session() {
    local callback="$1"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log WARN "Config nicht gefunden: $CONFIG_FILE — noch keine Sessions konfiguriert (siehe: controller.sh new)"
        return 0
    fi
    while IFS=';' read -r name workdir resume extra status || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(trim "$name")"
        workdir="$(trim "${workdir:-}")"
        resume="$(trim "${resume:-}")"
        extra="$(trim "${extra:-}")"
        status="$(trim "${status:-}")"
        [[ -z "$status" ]] && status="active"
        "$callback" "$name" "$workdir" "$resume" "$extra" "$status"
    done < "$CONFIG_FILE"
}

session_exists() { tmux_ has-session -t "=$1" 2>/dev/null; }

session_defined() {
    local target="$1" name
    [[ -f "$CONFIG_FILE" ]] || return 1
    while IFS=';' read -r name _ || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        [[ "$(trim "$name")" == "$target" ]] && return 0
    done < "$CONFIG_FILE"
    return 1
}

# Gibt zu einer Nummer (aus "list") den zugehörigen Session-Namen aus,
# oder den Namen unverändert zurück falls kein reiner Zahlenwert übergeben wurde.
resolve_target() {
    local arg="$1"
    if [[ "$arg" =~ ^[0-9]+$ ]]; then
        local idx=0 name found=""
        require_config
        while IFS=';' read -r name _ || [[ -n "$name" ]]; do
            [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
            idx=$((idx + 1))
            if [[ "$idx" == "$arg" ]]; then found="$(trim "$name")"; break; fi
        done < "$CONFIG_FILE"
        [[ -n "$found" ]] || { log ERROR "Keine Session mit Nummer $arg (siehe: controller.sh list)"; exit 1; }
        echo "$found"
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
}

# Gibt das Workdir-Feld der Session $1 aus sessions.conf zurück (leer,
# falls nicht gefunden).
config_get_workdir() {
    local target="$1" line name workdir
    [[ -f "$CONFIG_FILE" ]] || return 0
    while IFS='' read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        IFS=';' read -r name workdir _ <<< "$line"
        if [[ "$(trim "$name")" == "$target" ]]; then
            trim "${workdir:-}"
            return 0
        fi
    done < "$CONFIG_FILE"
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
        return 0
    fi
    if session_exists "$name"; then
        log INFO "[$name] läuft bereits, überspringe"
        return 0
    fi
    if [[ -n "$workdir" && ! -d "$workdir" ]]; then
        log ERROR "[$name] Arbeitsverzeichnis fehlt: $workdir"
        return 1
    fi
    local cmd
    cmd="$(build_cmd "$name" "$resume" "$extra")"
    log INFO "[$name] starte: $cmd (cwd=${workdir:-$HOME})"
    tmux_ new-session -d -s "$name" -c "${workdir:-$HOME}" "$cmd"
    tmux_ pipe-pane -t "$name" -o "cat >> '$LOG_DIR/$name.log'"
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
    printf '  [%-8s] [%-8s] %-20s %s\n' "$status" "$running" "$name" "$workdir"
}

cmd_start_all() { each_session start_one; }
cmd_stop_all() { each_session stop_one; }
cmd_status_all() { echo "Claude CLI Sessions ($TMUX_SOCK):"; each_session status_one; }
cmd_restart_all() { cmd_stop_all; sleep 1; cmd_start_all; }

# Nummerierte Übersicht aller konfigurierten Sessions (auch archivierte),
# als Basis für "controller.sh archive/unarchive <nummer>".
cmd_list() {
    require_config
    local idx=0 name workdir resume extra status running
    printf '%-3s %-9s %-9s %-20s %s\n' "Nr" "Status" "Läuft" "Name" "Workdir"
    while IFS=';' read -r name workdir resume extra status || [[ -n "$name" ]]; do
        [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
        name="$(trim "$name")"; workdir="$(trim "${workdir:-}")"; status="$(trim "${status:-}")"
        [[ -z "$status" ]] && status="active"
        idx=$((idx + 1))
        running="stopped"
        session_exists "$name" && running="running"
        printf '%-3s %-9s %-9s %-20s %s\n' "$idx" "$status" "$running" "$name" "$workdir"
    done < "$CONFIG_FILE"
}

# Legt ein neues Projekt an: Verzeichnis erstellen, in sessions.conf
# eintragen und sofort starten.
cmd_new() {
    local name="${1:?Usage: controller.sh new <name> [workdir] [resume] [extra_args]}"
    local workdir="${2:-$PROJECTS_BASE_DIR/$name}"
    local resume="${3-last}"
    local extra="${4:-}"

    ensure_config
    if session_defined "$name"; then
        log ERROR "[$name] existiert bereits in $CONFIG_FILE"
        exit 1
    fi

    mkdir -p "$workdir"
    log INFO "[$name] Verzeichnis angelegt: $workdir"

    printf '%s;%s;%s;%s;active\n' "$name" "$workdir" "$resume" "$extra" >> "$CONFIG_FILE"
    log INFO "[$name] in $CONFIG_FILE eingetragen"

    trust_project_dir "$workdir"
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
    local target="${1:?Usage: controller.sh delete <nummer|name> [--purge-workdir]}"
    local purge="${2:-}"
    local name; name="$(resolve_target "$target")"
    session_defined "$name" || { log ERROR "[$name] nicht in $CONFIG_FILE gefunden"; exit 1; }

    local workdir
    workdir="$(config_get_workdir "$name")"

    stop_one "$name"
    config_remove_entry "$name"
    log INFO "[$name] aus $CONFIG_FILE entfernt"

    if [[ "$purge" == "--purge-workdir" ]]; then
        if [[ -n "$workdir" && -d "$workdir" ]]; then
            rm -rf -- "$workdir"
            log INFO "[$name] Arbeitsverzeichnis gelöscht: $workdir"
        fi
    elif [[ -n "$workdir" ]]; then
        log INFO "[$name] Arbeitsverzeichnis bleibt erhalten: $workdir (mit --purge-workdir zusätzlich löschen)"
    fi
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
        sleep "$SUPERVISE_INTERVAL"
        each_session start_one
    done
}

usage() {
    cat <<EOF
Usage: $0 <command> [args]

Sessions verwalten:
  start                  Alle aktiven Sessions starten (idempotent, überspringt archivierte)
  stop                   Alle Sessions stoppen
  restart                Stop + Start
  status                 Status aller Sessions anzeigen
  list                   Nummerierte Übersicht aller Sessions (für archive/unarchive/attach)
  attach <nr|name>       An eine laufende Session anhängen (Ctrl-b d zum Lösen)
  supervise              Sessions starten und dauerhaft überwachen (für systemd)

Projekte verwalten:
  new <name> [workdir] [resume] [extra_args]
                         Neues Projekt anlegen: Verzeichnis erstellen (Default:
                         $PROJECTS_BASE_DIR/<name>), in sessions.conf eintragen, starten
  archive <nr|name>      Session stoppen und archivieren (kein Autostart mehr)
  unarchive <nr|name>    Archivierte Session wieder aktivieren (Start separat nötig)
  delete <nr|name> [--purge-workdir]
                         Session stoppen und Eintrag komplett aus sessions.conf
                         entfernen (nicht nur archivieren). Arbeitsverzeichnis
                         bleibt standardmäßig erhalten, --purge-workdir löscht
                         es zusätzlich unwiderruflich.

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
        status)     cmd_status_all ;;
        list)       cmd_list ;;
        attach)     cmd_attach "${1:-}" ;;
        supervise)  cmd_supervise ;;
        new)        cmd_new "$@" ;;
        archive)    cmd_archive "${1:-}" ;;
        unarchive)  cmd_unarchive "${1:-}" ;;
        delete)     cmd_delete "${1:-}" "${2:-}" ;;
        *)          usage; exit 1 ;;
    esac
}

main "$@"
