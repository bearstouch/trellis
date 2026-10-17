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
end
