# Bash-Completion fuer controller.sh.
#
# Einbinden, z.B. in ~/.bashrc:
#   source /pfad/zu/claude-cli-controller/completions/claude-cli-controller.bash
#
# Vervollstaendigt nur den Subcommand und - fuer Kommandos, die eine
# Session referenzieren - die Nummer aus "list" (1..N), keine Namen: viele
# reale Session-Namen enthalten Leerzeichen (siehe docs/SESSIONS.md), und
# Bash-Completion mit space-haltigen compgen-Woertern ist ohne deutlich
# mehr Aufwand (IFS-Handling, Quoting der COMPREPLY-Eintraege) fragil -
# die ohnehin ueberall unterstuetzten Nummern sind hier der robustere Weg.

_claude_cli_controller() {
    local cur cmd
    cur="${COMP_WORDS[COMP_CWORD]}"
    local commands="start stop restart status list attach supervise new archive unarchive rename edit delete backup restore"

    if [[ $COMP_CWORD -eq 1 ]]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
        return 0
    fi

    cmd="${COMP_WORDS[1]}"
    case "$cmd" in
        attach|archive|unarchive|rename|edit)
            if [[ $COMP_CWORD -eq 2 ]]; then
                local ctl="${COMP_WORDS[0]}" count
                count="$("$ctl" list 2>/dev/null | tail -n +2 | wc -l)"
                [[ "$count" -gt 0 ]] && COMPREPLY=( $(compgen -W "$(seq 1 "$count")" -- "$cur") )
            fi
            ;;
        delete)
            case "$COMP_CWORD" in
                2)
                    local ctl="${COMP_WORDS[0]}" count
                    count="$("$ctl" list 2>/dev/null | tail -n +2 | wc -l)"
                    [[ "$count" -gt 0 ]] && COMPREPLY=( $(compgen -W "$(seq 1 "$count")" -- "$cur") )
                    ;;
                3) COMPREPLY=( $(compgen -W "--purge-workdir" -- "$cur") ) ;;
                4) COMPREPLY=( $(compgen -W "--force" -- "$cur") ) ;;
            esac
            ;;
        status)
            [[ $COMP_CWORD -eq 2 ]] && COMPREPLY=( $(compgen -W "--json" -- "$cur") )
            ;;
        restore)
            [[ $COMP_CWORD -eq 3 ]] && COMPREPLY=( $(compgen -W "--force" -- "$cur") )
            ;;
    esac
}

complete -F _claude_cli_controller controller.sh
complete -F _claude_cli_controller ./controller.sh
