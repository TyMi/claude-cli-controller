#!/usr/bin/env bats
#
# Verhaltenstests für controller.sh (Bats: https://github.com/bats-core/bats-core).
# Lokal ausführen: bats test/controller.bats
# Deckt zuvor gefundene und gefixte Probleme (Shell-Injection, Backoff,
# Purge-Leitplanken, resume-Validierung u.a.) als dauerhafte Regressionstests,
# statt sie nur einmalig manuell nachzustellen.
#
# CLAUDE_BIN=/bin/true simuliert die Claude-CLI (echtes tmux wird benutzt,
# aber ohne echten "claude"-Prozess/Login - für die reine Controller-Logik
# ausreichend). Der Stopp per zwei C-c ist NICHT abgedeckt, das braucht den
# echten "claude"-Prozess und damit einen eingeloggten Account.

setup() {
    CTL="$BATS_TEST_DIRNAME/../controller.sh"
    TESTDIR="$(mktemp -d)"
    export CLAUDE_CTRL_CONFIG="$TESTDIR/sessions.conf"
    export CLAUDE_CTRL_STATE_DIR="$TESTDIR/state"
    export CLAUDE_CTRL_PROJECTS_DIR="$TESTDIR/projects"
    export CLAUDE_BIN="/bin/true"
    export CLAUDE_CTRL_REMOTE_CONTROL=0
    export CLAUDE_CTRL_AUTO_TRUST=0
    mkdir -p "$TESTDIR/projects"
}

teardown() {
    # Falls ein Test einen Hintergrund-"supervise"-Prozess gestartet hat
    # (PID in supervise.pid abgelegt): IMMER hier abräumen, nicht inline im
    # Test - eine fehlschlagende Assertion im Testkörper (unter Bats'
    # errexit) bricht die Testfunktion sofort ab und überspringt jeden
    # inline-Cleanup danach. Ohne diesen Schritt bleibt die "while true"-
    # Supervisor-Schleife verwaist laufen, und Bats wartet beim nächsten
    # Test offenbar auf alle Kindprozesse der Session, bevor es weitermacht -
    # das ganze Suite-Run hängt dann.
    if [[ -f "$TESTDIR/supervise.pid" ]]; then
        local pid; pid="$(cat "$TESTDIR/supervise.pid")"
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    tmux -S "$TESTDIR/state/tmux.sock" kill-server >/dev/null 2>&1 || true
    rm -rf "$TESTDIR"
}

# --- Shell-Injection über den Session-Namen ---

@test "new rejects shell injection in session name" {
    run "$CTL" new "poc'; touch $TESTDIR/PWNED; echo '"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ungültiger Session-Name"* ]]
    [ ! -f "$TESTDIR/PWNED" ]
}

@test "new accepts names with spaces and umlauts" {
    run "$CTL" new "CamDisplay Schützen"
    [ "$status" -eq 0 ]
    run "$CTL" list
    [[ "$output" == *"CamDisplay Schützen"* ]]
}

# --- Rein numerische Namen ---

@test "new rejects purely numeric session name" {
    run "$CTL" new "2024"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ungültiger Session-Name"* ]]
}

@test "new accepts a name that mixes letters and digits" {
    run "$CTL" new "Projekt2024"
    [ "$status" -eq 0 ]
}

# --- Voller Lebenszyklus ---

@test "full lifecycle: new, archive, unarchive, delete" {
    run "$CTL" new "Kunde A"
    [ "$status" -eq 0 ]
    run "$CTL" archive 1
    [ "$status" -eq 0 ]
    run "$CTL" list
    [[ "$output" == *"archived"* ]]
    run "$CTL" unarchive 1
    [ "$status" -eq 0 ]
    run "$CTL" delete 1 --purge-workdir
    [ "$status" -eq 0 ]
    run "$CTL" list
    [[ "$output" != *"Kunde A"* ]]
}

# --- Duplikat-Erkennung ---

@test "duplicate session names: first definition wins, warning logged" {
    mkdir -p "$TESTDIR/projects/demo" "$TESTDIR/projects/demo2"
    cat > "$CLAUDE_CTRL_CONFIG" <<EOF
demo;$TESTDIR/projects/demo;;;active
demo;$TESTDIR/projects/demo2;;;active
EOF
    run "$CTL" list
    [[ "$output" == *"mehrfach in"* ]]
    local count
    count="$(echo "$output" | grep -c '^1 ')"
    [ "$count" -eq 1 ]
}

# --- Robustheit von each_session (ursprünglicher set -e Bug) ---

@test "a session with missing workdir does not block starting others" {
    cat > "$CLAUDE_CTRL_CONFIG" <<EOF
broken;$TESTDIR/does-not-exist;;;active
healthy;$TESTDIR/projects;;;active
EOF
    run "$CTL" start
    [[ "$output" == *"Arbeitsverzeichnis fehlt"* ]]
    [[ "$output" == *"[healthy] starte"* ]]
}

# --- Backoff ---

@test "backoff: recent failure blocks immediate retry" {
    mkdir -p "$TESTDIR/projects/demo" "$TESTDIR/state/backoff"
    echo "demo;$TESTDIR/projects/demo;;;active" > "$CLAUDE_CTRL_CONFIG"
    echo "1;$(date +%s)" > "$TESTDIR/state/backoff/demo"
    run "$CTL" start
    [[ "$output" != *"[demo] starte"* ]]
}

@test "backoff: expired window allows retry" {
    mkdir -p "$TESTDIR/projects/demo" "$TESTDIR/state/backoff"
    echo "demo;$TESTDIR/projects/demo;;;active" > "$CLAUDE_CTRL_CONFIG"
    echo "1;$(($(date +%s) - 20))" > "$TESTDIR/state/backoff/demo"
    run "$CTL" start
    [[ "$output" == *"[demo] starte"* ]]
}

@test "backoff resets after a session stays running" {
    mkdir -p "$TESTDIR/projects/demo" "$TESTDIR/state/backoff"
    echo "demo;$TESTDIR/projects/demo;;;active" > "$CLAUDE_CTRL_CONFIG"
    echo "4;$(($(date +%s) - 1000))" > "$TESTDIR/state/backoff/demo"
    CLAUDE_BIN="/bin/sleep 30" run "$CTL" start
    run "$CTL" start
    [[ "$output" == *"läuft bereits"* ]]
    [ ! -f "$TESTDIR/state/backoff/demo" ]
}

# --- Supervisor: sessions.conf pro Tick neu einlesen ---
#
# Bewusst KEIN Test über "archive" einer laufenden Session: archive stoppt
# selbst aktiv (2x C-c + Kill-Fallback, siehe stop_one), das würde mit dem
# Supervisor-Tick um dieselbe tmux-Session wettlaufen und den Endzustand
# zufällig machen (beim Schreiben entdeckt - der archive-eigene
# Kill-Fallback kann eine vom Bug neu gestartete Session durch Zufall
# wieder einholen, was den Test fälschlich grün macht). Stattdessen eine
# Transition, die selbst nichts in tmux anfasst: "unarchive" ändert nur
# die Config-Datei, der Supervisor allein entscheidet über den Start.

@test "supervise picks up an unarchive from another invocation without needing a restart" {
    mkdir -p "$TESTDIR/projects/demo"
    echo "demo;$TESTDIR/projects/demo;;;archived" > "$CLAUDE_CTRL_CONFIG"
    CLAUDE_BIN="/bin/sleep 30" CLAUDE_CTRL_INTERVAL=1 "$CTL" supervise &
    echo "$!" > "$TESTDIR/supervise.pid"

    # Archivierte Session: der Supervisor darf sie über mehrere Ticks hinweg
    # nie starten.
    sleep 2.5
    ! tmux -S "$TESTDIR/state/tmux.sock" has-session -t "=demo" 2>/dev/null

    run "$CTL" unarchive demo
    [ "$status" -eq 0 ]

    # Ohne den Reload-Fix bliebe der längst laufende Supervisor-Prozess bei
    # seinem Config-Stand vom eigenen Start (status=archived) und würde
    # "demo" nie hochfahren.
    local i
    for i in $(seq 1 20); do
        tmux -S "$TESTDIR/state/tmux.sock" has-session -t "=demo" 2>/dev/null && break
        sleep 0.2
    done
    tmux -S "$TESTDIR/state/tmux.sock" has-session -t "=demo"
}

# --- Leitplanken für --purge-workdir ---

@test "delete --purge-workdir refuses path outside PROJECTS_BASE_DIR without --force" {
    mkdir -p "$TESTDIR/outside"
    run "$CTL" new proja "$TESTDIR/outside"
    [ "$status" -eq 0 ]
    run "$CTL" delete 1 --purge-workdir
    [ "$status" -ne 0 ]
    [ -d "$TESTDIR/outside" ]
}

@test "delete --purge-workdir --force deletes path outside PROJECTS_BASE_DIR" {
    mkdir -p "$TESTDIR/outside"
    run "$CTL" new proja "$TESTDIR/outside"
    run "$CTL" delete 1 --purge-workdir --force
    [ "$status" -eq 0 ]
    [ ! -d "$TESTDIR/outside" ]
}

@test "delete --purge-workdir refuses HOME even with --force" {
    local fake_home="$TESTDIR/fakehome"
    mkdir -p "$fake_home"
    HOME="$fake_home" run "$CTL" new homeproj "$fake_home"
    HOME="$fake_home" run "$CTL" delete 1 --purge-workdir --force
    [ "$status" -ne 0 ]
    [ -d "$fake_home" ]
}

# --- resume-Validierung ---

@test "resume field: shell injection payload is rejected, not executed" {
    mkdir -p "$TESTDIR/projects/demo"
    printf 'demo;%s/projects/demo;$(touch %s/PWNED_RESUME)_evil;;active\n' "$TESTDIR" "$TESTDIR" > "$CLAUDE_CTRL_CONFIG"
    run "$CTL" start
    [[ "$output" == *"ungültiger resume-Wert"* ]]
    [ ! -f "$TESTDIR/PWNED_RESUME" ]
}

@test "resume field: a valid UUID is accepted" {
    mkdir -p "$TESTDIR/projects/demo"
    echo "demo;$TESTDIR/projects/demo;16999acc-1280-4d8f-b168-44a594876209;;active" > "$CLAUDE_CTRL_CONFIG"
    run "$CTL" start
    [[ "$output" == *"--resume 16999acc-1280-4d8f-b168-44a594876209"* ]]
}

@test "warns when sessions.conf is writable by other local users" {
    echo "demo;$TESTDIR/projects;;;active" > "$CLAUDE_CTRL_CONFIG"
    chmod 666 "$CLAUDE_CTRL_CONFIG"
    run "$CTL" list
    [[ "$output" == *"beschreibbar"* ]]
}

@test "no permission warning when sessions.conf is 600" {
    echo "demo;$TESTDIR/projects;;;active" > "$CLAUDE_CTRL_CONFIG"
    chmod 600 "$CLAUDE_CTRL_CONFIG"
    run "$CTL" list
    [[ "$output" != *"beschreibbar"* ]]
}

# --- Verzeichnis-Rechte ---

@test "state/log/backoff directories are created with mode 700" {
    run "$CTL" list
    [ "$(stat -c '%a' "$TESTDIR/state")" = "700" ]
    [ "$(stat -c '%a' "$TESTDIR/state/logs")" = "700" ]
    [ "$(stat -c '%a' "$TESTDIR/state/backoff")" = "700" ]
}

# --- status --json ---

@test "status --json produces valid JSON" {
    mkdir -p "$TESTDIR/projects/demo"
    run "$CTL" new demo "$TESTDIR/projects/demo"
    run "$CTL" status --json
    [ "$status" -eq 0 ]
    echo "$output" | python3 -c "import json,sys; json.load(sys.stdin)"
}

# --- rename/edit ---

@test "rename updates the config entry" {
    mkdir -p "$TESTDIR/projects/demo"
    echo "demo;$TESTDIR/projects/demo;;;active" > "$CLAUDE_CTRL_CONFIG"
    run "$CTL" rename 1 "demo-neu"
    [ "$status" -eq 0 ]
    run "$CTL" list
    [[ "$output" == *"demo-neu"* ]]
}

@test "rename refuses a name that already exists" {
    mkdir -p "$TESTDIR/projects/a" "$TESTDIR/projects/b"
    cat > "$CLAUDE_CTRL_CONFIG" <<EOF
eins;$TESTDIR/projects/a;;;active
zwei;$TESTDIR/projects/b;;;active
EOF
    run "$CTL" rename eins zwei
    [ "$status" -ne 0 ]
}

@test "edit changes only the specified field" {
    mkdir -p "$TESTDIR/projects/demo"
    echo "demo;$TESTDIR/projects/demo;last;;active" > "$CLAUDE_CTRL_CONFIG"
    run "$CTL" edit 1 --extra-args "--permission-mode acceptEdits"
    [ "$status" -eq 0 ]
    run cat "$CLAUDE_CTRL_CONFIG"
    [[ "$output" == *"demo;$TESTDIR/projects/demo;last;--permission-mode acceptEdits;active"* ]]
}

@test "edit with no flags fails" {
    mkdir -p "$TESTDIR/projects/demo"
    echo "demo;$TESTDIR/projects/demo;;;active" > "$CLAUDE_CTRL_CONFIG"
    run "$CTL" edit 1
    [ "$status" -ne 0 ]
}

# --- Semikolon/Zeilenumbruch in Config-Feldern ---

@test "new rejects a semicolon in extra_args and writes nothing" {
    run "$CTL" new semi "" "" "--foo;bar"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Semikolon"* ]]
    ! grep -q "^semi;" "$CLAUDE_CTRL_CONFIG"
}

@test "new rejects a semicolon in workdir" {
    run "$CTL" new semi "$TESTDIR/a;b"
    [ "$status" -ne 0 ]
    [ ! -e "$TESTDIR/a;b" ]
}

@test "edit rejects a semicolon and leaves the config unchanged" {
    mkdir -p "$TESTDIR/projects/demo"
    echo "demo;$TESTDIR/projects/demo;last;;active" > "$CLAUDE_CTRL_CONFIG"
    run "$CTL" edit 1 --extra-args "--x;--y"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Semikolon"* ]]
    run cat "$CLAUDE_CTRL_CONFIG"
    [ "$output" = "demo;$TESTDIR/projects/demo;last;;active" ]
}

# --- delete-Argumente ---

@test "delete --force without --purge-workdir is refused, entry kept" {
    run "$CTL" new proja
    run "$CTL" delete 1 --force
    [ "$status" -ne 0 ]
    [[ "$output" == *"--purge-workdir"* ]]
    grep -q "^proja;" "$CLAUDE_CTRL_CONFIG"
}

@test "delete rejects unknown options, entry kept" {
    run "$CTL" new proja
    run "$CTL" delete 1 --bogus
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unbekannte Option"* ]]
    grep -q "^proja;" "$CLAUDE_CTRL_CONFIG"
}

@test "delete accepts --force before --purge-workdir" {
    mkdir -p "$TESTDIR/outside"
    run "$CTL" new proja "$TESTDIR/outside"
    run "$CTL" delete 1 --force --purge-workdir
    [ "$status" -eq 0 ]
    [ ! -d "$TESTDIR/outside" ]
}

# --- config_rewrite erhält Kommentare ---

@test "rename and archive keep comments and other entries intact" {
    mkdir -p "$TESTDIR/projects/a" "$TESTDIR/projects/b"
    printf '# Kommentar\na;%s;;;active\n\nb;%s;last;;active\n' "$TESTDIR/projects/a" "$TESTDIR/projects/b" > "$CLAUDE_CTRL_CONFIG"
    run "$CTL" rename 1 aa
    [ "$status" -eq 0 ]
    run "$CTL" archive 2
    [ "$status" -eq 0 ]
    run cat "$CLAUDE_CTRL_CONFIG"
    # Leerzeilen werden von "run" nicht zuverlässig als eigene Einträge
    # in $lines abgebildet - daher über die Datei direkt vergleichen.
    [ "$(cat "$CLAUDE_CTRL_CONFIG")" = "$(printf '# Kommentar\naa;%s;;;active\n\nb;%s;last;;archived' "$TESTDIR/projects/a" "$TESTDIR/projects/b")" ]
}

# --- backup/restore ---

# HOME wird hier bewusst auf ein Fake-Verzeichnis isoliert - sonst würde
# "backup" das ECHTE ~/.claude des Rechners einpacken (langsam, hängt vom
# Host-Zustand ab, potenziell sensible Daten in einem Test-Artefakt).
@test "backup creates a tar.gz containing sessions.conf" {
    local fake_home="$TESTDIR/fakehome"
    mkdir -p "$fake_home/.claude"
    echo "demo;$TESTDIR/projects;;;active" > "$CLAUDE_CTRL_CONFIG"
    HOME="$fake_home" run "$CTL" backup "$TESTDIR/mybackup.tar.gz"
    [ "$status" -eq 0 ]
    [ -f "$TESTDIR/mybackup.tar.gz" ]
    run tar -tzf "$TESTDIR/mybackup.tar.gz"
    [[ "$output" == *"sessions.conf"* ]]
}

@test "restore without --force is refused" {
    local fake_home="$TESTDIR/fakehome"
    mkdir -p "$fake_home/.claude"
    echo "demo;$TESTDIR/projects;;;active" > "$CLAUDE_CTRL_CONFIG"
    HOME="$fake_home" run "$CTL" backup "$TESTDIR/mybackup.tar.gz"
    HOME="$fake_home" run "$CTL" restore "$TESTDIR/mybackup.tar.gz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--force"* ]]
}
