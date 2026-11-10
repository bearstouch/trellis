# Trellis shell integration for fish (protocol v1).
# Trellis prepends this data directory to XDG_DATA_DIRS; restore the user's value first.
if set -q TRELLIS_FISH_XDG_DATA_DIRS
    set -gx XDG_DATA_DIRS "$TRELLIS_FISH_XDG_DATA_DIRS"
    set -e TRELLIS_FISH_XDG_DATA_DIRS
else
    set -e XDG_DATA_DIRS
end

# The nonce authenticates marks; keep it unexported so child processes never see it.
set -g __trellis_si_nonce "$TRELLIS_SHELL_INTEGRATION_NONCE"
set -l __trellis_si_version "$TRELLIS_SHELL_INTEGRATION"
set -e TRELLIS_SHELL_INTEGRATION_NONCE
set -e TRELLIS_SHELL_INTEGRATION
# The typed-agent hook channel (FR-AG18) reaches only the agents the functions below run.
set -g __trellis_si_agent_socket "$TRELLIS_AGENT_SOCKET"
set -g __trellis_si_agent_nonce "$TRELLIS_AGENT_NONCE"
set -g __trellis_si_agent_wiring
if test -n "$TRELLIS_AGENT_WIRING"
    set __trellis_si_agent_wiring (string split \n -- "$TRELLIS_AGENT_WIRING")
end
set -e TRELLIS_AGENT_SOCKET
set -e TRELLIS_AGENT_NONCE
set -e TRELLIS_AGENT_WIRING

if status is-interactive; and test -n "$__trellis_si_nonce"; and test "$__trellis_si_version" = 1; and not set -q __trellis_si_installed
    set -g __trellis_si_installed 1

    function __trellis_si_prompt --on-event fish_prompt
        printf '\e]133;A;trellis=%s;cwd=%s\a' $__trellis_si_nonce (string escape --style=url -- $PWD)
    end

    function __trellis_si_preexec --on-event fish_preexec
        printf '\e]133;C;trellis=%s;cmdline_url=%s\a' $__trellis_si_nonce (string escape --style=url -- (string sub -l 4096 -- "$argv[1]"))
    end

    function __trellis_si_postexec --on-event fish_postexec
        set -l ret $status
        printf '\e]133;D;%s;trellis=%s\a' $ret $__trellis_si_nonce
    end

    # Runs a typed agent with Trellis's hook wiring (FR-AG18). A record is
    # `<executable>\t<count>\t<count environment words>\t<arguments>`; Trellis always sends arguments.
    function __trellis_si_agent
        set -l exe $argv[1]
        set -e argv[1]
        for line in $__trellis_si_agent_wiring
            set -l rec (string split \t -- $line)
            test "$rec[1]" = "$exe"; or continue
            if test -z "$__trellis_si_agent_nonce"; or not string match -qr '^[0-9]+$' -- "$rec[2]"; or test (count $rec) -lt (math 3 + $rec[2])
                break
            end
            set -l n $rec[2]
            set -l words
            if test $n -gt 0
                set words $rec[3..(math 2 + $n)]
            end
            command env TRELLIS_AGENT_SOCKET=$__trellis_si_agent_socket TRELLIS_AGENT_NONCE=$__trellis_si_agent_nonce $words $exe $rec[(math 3 + $n)..-1] $argv
            return $status
        end
        command $exe $argv
    end

    # On the first prompt, after config.fish, so the user's own function of the same name wins.
    function __trellis_si_agent_define --on-event fish_prompt
        functions -e __trellis_si_agent_define
        for line in $__trellis_si_agent_wiring
            set -l exe (string split -m 1 \t -- $line)[1]
            test -n "$exe"; and test "$exe" != "$line"; or continue
            functions -q -- $exe; and continue
            function $exe
                __trellis_si_agent (status current-function) $argv
            end
        end
    end
end
