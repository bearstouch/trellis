# Trellis shell integration for bash 3.2+ (protocol v1).
# Trellis starts bash with --rcfile pointing here, so emulate the login startup it replaced.

# The nonce authenticates marks; keep it unexported so child processes never see it.
__trellis_si_nonce="${TRELLIS_SHELL_INTEGRATION_NONCE-}"
__trellis_si_version="${TRELLIS_SHELL_INTEGRATION-}"
__trellis_si_login="${TRELLIS_BASH_LOGIN-}"
# The typed-agent hook channel (FR-AG18) reaches only the agents the functions below run.
__trellis_si_agent_socket="${TRELLIS_AGENT_SOCKET-}"
__trellis_si_agent_nonce="${TRELLIS_AGENT_NONCE-}"
__trellis_si_agent_wiring="${TRELLIS_AGENT_WIRING-}"
# The prompt chosen in Settings (FR-SI10); empty leaves the user's prompt alone.
__trellis_si_prompt_preset="${TRELLIS_PROMPT_PRESET-}"
builtin unset TRELLIS_SHELL_INTEGRATION_NONCE TRELLIS_SHELL_INTEGRATION TRELLIS_BASH_LOGIN TRELLIS_AGENT_SOCKET TRELLIS_AGENT_NONCE TRELLIS_AGENT_WIRING \
    TRELLIS_PROMPT_PRESET
builtin export -n __trellis_si_nonce __trellis_si_version __trellis_si_login __trellis_si_agent_socket __trellis_si_agent_nonce __trellis_si_agent_wiring \
    __trellis_si_prompt_preset 2>/dev/null

if [ -n "$__trellis_si_login" ]; then
    [ -r /etc/profile ] && builtin source /etc/profile
    if [ -r "$HOME/.bash_profile" ]; then
        builtin source "$HOME/.bash_profile"
    elif [ -r "$HOME/.bash_login" ]; then
        builtin source "$HOME/.bash_login"
    elif [ -r "$HOME/.profile" ]; then
        builtin source "$HOME/.profile"
    fi
elif [ -r "$HOME/.bashrc" ]; then
    builtin source "$HOME/.bashrc"
fi
builtin unset __trellis_si_login

if [[ $- == *i* && -n "$__trellis_si_nonce" && "$__trellis_si_version" == 1 && -z "${__trellis_si_installed-}" ]]; then
    __trellis_si_installed=1
    __trellis_si_running=
    __trellis_si_ready=

    # Percent-encodes $1 into REPLY so paths and commands cannot break the OSC frame.
    __trellis_si_encode() {
        local LC_ALL=C s="$1" out= c n i
        for (( i = 0; i < ${#s}; i++ )); do
            c="${s:i:1}"
            case "$c" in
                [a-zA-Z0-9/._~-]) out="$out$c" ;;
                *) builtin printf -v n '%d' "'$c"; builtin printf -v c '%%%02X' $(( n & 255 )); out="$out$c" ;;
            esac
        done
        REPLY="$out"
    }

    __trellis_si_status=0
    __trellis_si_precmd() {
        local ret=$? REPLY
        __trellis_si_status=$ret
        __trellis_si_ready=
        if [ -n "$__trellis_si_running" ]; then
            builtin printf '\033]133;D;%s;trellis=%s\007' "$ret" "$__trellis_si_nonce"
            __trellis_si_running=
        fi
        __trellis_si_encode "$PWD"
        builtin printf '\033]133;A;trellis=%s;cwd=%s\007' "$__trellis_si_nonce" "$REPLY"
        # B carries no nonce: PS1 is often exported, and B changes no Trellis state.
        local mark='\[\033]133;B\007\]'
        case "$PS1" in *"$mark") ;; *) PS1="$PS1$mark" ;; esac
        return $ret
    }

    # Runs last in PROMPT_COMMAND: only the next DEBUG trap after this is a typed command.
    __trellis_si_arm() { local ret=$?; __trellis_si_ready=1; return $ret; }

    __trellis_si_preexec() {
        [ -n "$__trellis_si_ready" ] || return 0
        [ -n "${COMP_LINE-}" ] && return 0
        __trellis_si_ready=
        # An empty command line runs PROMPT_COMMAND directly; that is not a command.
        [ "$BASH_COMMAND" = __trellis_si_precmd ] && return 0
        local REPLY
        __trellis_si_encode "${BASH_COMMAND:0:4096}"
        builtin printf '\033]133;C;trellis=%s;cmdline_url=%s\007' "$__trellis_si_nonce" "$REPLY"
        __trellis_si_running=1
    }

    case "$__trellis_si_prompt_preset" in
        minimal | classic | directory | compact | git | twoLine | status | clock | lambda | bracketed) ;;
        *) __trellis_si_prompt_preset= ;;
    esac

    # The checked-out branch, or a short commit when detached, into REPLY. Reads .git/HEAD itself: running git
    # before every prompt is slow, and macOS's /usr/bin/git stub offers to install the developer tools.
    __trellis_si_git_branch() {
        REPLY=
        local d="$PWD" g line= head=
        while [ ! -e "$d/.git" ]; do
            if [ "$d" = / ] || [ -z "$d" ]; then return 1; fi
            d="${d%/*}"
            [ -n "$d" ] || d=/
        done
        g="$d/.git"
        if [ -f "$g" ]; then
            [ -r "$g" ] && { IFS= read -r line || [ -n "$line" ]; } < "$g"
            case "$line" in "gitdir: "*) g="${line#gitdir: }" ;; *) return 1 ;; esac
            case "$g" in /*) ;; *) g="$d/$g" ;; esac
        fi
        # A regular file only: a FIFO or device named HEAD in an unpacked archive would block every prompt.
        [ -f "$g/HEAD" ] && [ -r "$g/HEAD" ] && { IFS= read -r head || [ -n "$head" ]; } < "$g/HEAD"
        case "$head" in
            "ref: refs/heads/"*) REPLY="${head#ref: refs/heads/}" ;;
            "ref: "*) REPLY="${head#ref: }" ;;
            *) REPLY="${head:0:7}" ;;
        esac
        [ -n "$REPLY" ]
    }

    # A value for PS1 in REPLY. With promptvars on, PS1 only names the variable: bash expands it when drawing the
    # prompt and never re-evaluates the result, so a directory or branch name can't run code. Without promptvars,
    # the text goes in with its backslashes doubled. Control characters become `?` first, so a name can't send the
    # terminal escape sequences.
    __trellis_si_prompt_value() {
        builtin printf -v "$1" '%s' "${!1//[[:cntrl:]]/?}"
        if builtin shopt -q promptvars; then REPLY="\${$1}"; else REPLY="${!1//\\/\\\\}"; fi
    }

    # Rebuilds PS1 for the chosen preset (FR-SI10). It runs after the user's PROMPT_COMMAND, so a theme can't undo
    # it, then puts back the B mark, which must stay at the end.
    __trellis_si_prompt() {
        local ret=$? REPLY e='\[\033[' pwd= folder= branch=
        local r="${e}0m\]" b="${e}1m\]" red="${e}31m\]" green="${e}32m\]" yellow="${e}33m\]" blue="${e}34m\]"
        local magenta="${e}35m\]" cyan="${e}36m\]" gray="${e}90m\]" ok="${e}32m\]"
        [ "$__trellis_si_status" = 0 ] || ok="$red"
        local arrow="$b${ok}❯$r"
        __trellis_si_p_path="$PWD"
        if [ "$PWD" = "$HOME" ]; then
            __trellis_si_p_path="~"
        elif [ -n "$HOME" ] && [ "$HOME" != / ] && [ "${PWD#"$HOME"/}" != "$PWD" ]; then
            __trellis_si_p_path="~/${PWD#"$HOME"/}"
        fi
        __trellis_si_p_folder="${PWD##*/}"
        [ "$__trellis_si_p_path" = "~" ] && __trellis_si_p_folder="~"
        [ -n "$__trellis_si_p_folder" ] || __trellis_si_p_folder=/
        __trellis_si_prompt_value __trellis_si_p_path; pwd="$REPLY"
        __trellis_si_prompt_value __trellis_si_p_folder; folder="$REPLY"
        case "$__trellis_si_prompt_preset" in
            git | twoLine)
                if __trellis_si_git_branch; then
                    __trellis_si_p_branch="$REPLY"
                    __trellis_si_prompt_value __trellis_si_p_branch; branch=" $magenta($REPLY)$r"
                fi
                ;;
        esac
        case "$__trellis_si_prompt_preset" in
            minimal) PS1="$arrow " ;;
            classic) PS1="$b$green\u@\h$r:$b$blue$pwd$r\$ " ;;
            directory) PS1="$cyan$pwd$r $arrow " ;;
            compact) PS1="$b$blue$folder$r $arrow " ;;
            git) PS1="$cyan$pwd$r$branch $arrow " ;;
            twoLine) PS1="${gray}╭─ $r$green\u@\h$r $b$blue$pwd$r$branch\n${gray}╰─$r$arrow " ;;
            status)
                if [ "$__trellis_si_status" = 0 ]; then PS1="${green}✔$r"; else PS1="$b${red}✘ $__trellis_si_status$r"; fi
                PS1="$PS1 $cyan$pwd$r ❯ "
                ;;
            clock) PS1="$gray[\A]$r $cyan$pwd$r $arrow " ;;
            lambda) PS1="$b${yellow}λ$r $blue$folder$r $b${ok}→$r " ;;
            bracketed) PS1="[$green\u@\h$r $blue$folder$r]\$ " ;;
        esac
        PS1="$PS1"'\[\033]133;B\007\]'
        return $ret
    }

    if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND=(__trellis_si_precmd "${PROMPT_COMMAND[@]}" ${__trellis_si_prompt_preset:+__trellis_si_prompt} __trellis_si_arm)
    else
        PROMPT_COMMAND="__trellis_si_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}${__trellis_si_prompt_preset:+; __trellis_si_prompt}; __trellis_si_arm"
    fi

    # Chain an existing DEBUG trap (bash-preexec and similar) instead of replacing it;
    # it runs first so its "$_" still sees the user's last argument.
    __trellis_si_debug=
    __trellis_si_trap="$(builtin trap -p DEBUG)"
    if [ -n "$__trellis_si_trap" ]; then
        builtin eval "builtin set -- $__trellis_si_trap"
        __trellis_si_debug="$3"
        builtin set --
    fi
    builtin trap "${__trellis_si_debug:+$__trellis_si_debug; }__trellis_si_preexec" DEBUG
    builtin unset __trellis_si_trap __trellis_si_debug

    # Runs a typed agent with Trellis's hook wiring (FR-AG18). A record is
    # `<executable>\t<count>\t<count environment words>\t<arguments>`.
    __trellis_si_agent() {
        local exe="$1" line= found= n
        shift
        while IFS= read -r line; do
            case "$line" in "$exe"$'\t'*) found=1; break ;; esac
        done <<< "$__trellis_si_agent_wiring"
        local -a rec
        [ -n "$found" ] && IFS=$'\t' read -r -a rec <<< "$line"
        n="${rec[1]-}"
        case "$n" in '' | *[!0-9]*) found= ;; esac
        if [ -z "$found" ] || [ -z "$__trellis_si_agent_nonce" ]; then
            command "$exe" "$@"
            return
        fi
        command env "TRELLIS_AGENT_SOCKET=$__trellis_si_agent_socket" "TRELLIS_AGENT_NONCE=$__trellis_si_agent_nonce" \
            "${rec[@]:2:n}" "$exe" "${rec[@]:2+n}" "$@"
    }

    # The user's files have run, so their own function or alias of the same name wins.
    if [ -n "$__trellis_si_agent_wiring" ]; then
        while IFS= read -r __trellis_si_line; do
            __trellis_si_exe="${__trellis_si_line%%$'\t'*}"
            [ -n "$__trellis_si_exe" ] && [ "$__trellis_si_exe" != "$__trellis_si_line" ] || continue
            # Trellis sends letters, digits and `._+-` only; checked again since the name is eval'd.
            case "$__trellis_si_exe" in *[!A-Za-z0-9._+-]* | [-.]*) continue ;; esac
            case "$(builtin type -t "$__trellis_si_exe" 2>/dev/null)" in alias | function | keyword | builtin) continue ;; esac
            builtin eval "$__trellis_si_exe() { __trellis_si_agent $__trellis_si_exe \"\$@\"; }"
        done <<< "$__trellis_si_agent_wiring"
        builtin unset __trellis_si_line __trellis_si_exe
    fi
fi
builtin unset __trellis_si_version
