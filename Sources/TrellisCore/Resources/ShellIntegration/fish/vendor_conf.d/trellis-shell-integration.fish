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
# The prompt chosen in Settings (FR-SI10); empty leaves the user's prompt alone.
set -g __trellis_si_prompt_preset "$TRELLIS_PROMPT_PRESET"
set -e TRELLIS_PROMPT_PRESET

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

    if contains -- "$__trellis_si_prompt_preset" minimal classic directory compact git twoLine status clock lambda bracketed
        # The checked-out branch, or a short commit when detached. Reads .git/HEAD itself: running git before every
        # prompt is slow, and macOS's /usr/bin/git stub offers to install the developer tools.
        function __trellis_si_git_branch
            set -l d $PWD
            while not test -e "$d/.git"
                if test "$d" = /; or test -z "$d"
                    return 1
                end
                set d (string replace -r '/[^/]*$' '' -- $d)
                test -n "$d"; or set d /
            end
            set -l g "$d/.git"
            if test -f "$g"
                test -r "$g"; or return 1
                read -l line <"$g"
                string match -q 'gitdir: *' -- "$line"; or return 1
                set g (string replace 'gitdir: ' '' -- "$line")
                string match -q '/*' -- "$g"; or set g "$d/$g"
            end
            # A regular file only: a FIFO or device named HEAD in an unpacked archive would block every prompt.
            test -f "$g/HEAD"; and test -r "$g/HEAD"; or return 1
            read -l head <"$g/HEAD"
            if string match -q 'ref: refs/heads/*' -- "$head"
                string replace 'ref: refs/heads/' '' -- "$head"
            else if string match -q 'ref: *' -- "$head"
                string replace 'ref: ' '' -- "$head"
            else if test -n "$head"
                string sub -l 7 -- "$head"
            else
                return 1
            end
        end

        # On the first prompt, after config.fish, so the preset replaces the user's fish_prompt (FR-SI10).
        function __trellis_si_prompt_define --on-event fish_prompt
            functions -e __trellis_si_prompt_define
            function fish_prompt
                set -l ret $status
                set -l normal (set_color normal)
                set -l ok (set_color -o green)
                test $ret -eq 0; or set ok (set_color -o red)
                set -l arrow "$ok""❯$normal"
                # Control characters become `?`, so a directory or branch name can't send escape sequences.
                set -l cwd (string replace -ra '[[:cntrl:]]' '?' -- "$PWD")
                set -l p $cwd
                set -l prefix (string sub -l (string length -- "$HOME/") -- "$cwd")
                if test "$PWD" = "$HOME"
                    set p '~'
                else if test -n "$HOME"; and test "$HOME" != /; and test "$prefix" = "$HOME/"
                    set p "~/"(string sub -s (math (string length -- "$HOME/") + 1) -- "$cwd")
                end
                set -l folder (string split -r -m 1 / -- $cwd)[-1]
                test "$p" = '~'; and set folder '~'
                test -n "$folder"; or set folder /
                set -l user $USER
                test -n "$user"; or set user (id -un)
                set -l userhost "$user@"(string split -m 1 . -- $hostname)[1]
                set -l branch ''
                set -l name
                if contains -- $__trellis_si_prompt_preset git twoLine; and set name (__trellis_si_git_branch)
                    set branch " "(set_color magenta)"("(string replace -ra '[[:cntrl:]]' '?' -- "$name")")$normal"
                end
                switch $__trellis_si_prompt_preset
                    case minimal
                        printf '%s ' "$arrow"
                    case classic
                        printf '%s' (set_color -o green)"$userhost$normal:"(set_color -o blue)"$p$normal\$ "
                    case directory
                        printf '%s' (set_color cyan)"$p$normal $arrow "
                    case compact
                        printf '%s' (set_color -o blue)"$folder$normal $arrow "
                    case git
                        printf '%s' (set_color cyan)"$p$normal$branch $arrow "
                    case twoLine
                        printf '%s\n%s' (set_color brblack)"╭─ $normal"(set_color green)"$userhost$normal "(set_color -o blue)"$p$normal$branch" \
                            (set_color brblack)"╰─$normal$arrow "
                    case status
                        if test $ret -eq 0
                            printf '%s' (set_color green)"✔$normal"
                        else
                            printf '%s' (set_color -o red)"✘ $ret$normal"
                        end
                        printf '%s' " "(set_color cyan)"$p$normal ❯ "
                    case clock
                        printf '%s' (set_color brblack)"["(date +%H:%M)"]$normal "(set_color cyan)"$p$normal $arrow "
                    case lambda
                        printf '%s' (set_color -o yellow)"λ$normal "(set_color blue)"$folder$normal $ok""→$normal "
                    case bracketed
                        printf '%s' "["(set_color green)"$userhost$normal "(set_color blue)"$folder$normal]\$ "
                end
            end
        end
    end
end
