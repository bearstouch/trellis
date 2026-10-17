# Trellis shell integration for bash 3.2+ (protocol v1).
# Trellis starts bash with --rcfile pointing here, so emulate the login startup it replaced.

# The nonce authenticates marks; keep it unexported so child processes never see it.
__trellis_si_nonce="${TRELLIS_SHELL_INTEGRATION_NONCE-}"
__trellis_si_version="${TRELLIS_SHELL_INTEGRATION-}"
__trellis_si_login="${TRELLIS_BASH_LOGIN-}"
builtin unset TRELLIS_SHELL_INTEGRATION_NONCE TRELLIS_SHELL_INTEGRATION TRELLIS_BASH_LOGIN
builtin export -n __trellis_si_nonce __trellis_si_version __trellis_si_login 2>/dev/null

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

    __trellis_si_precmd() {
        local ret=$? REPLY
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

    if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND=(__trellis_si_precmd "${PROMPT_COMMAND[@]}" __trellis_si_arm)
    else
        PROMPT_COMMAND="__trellis_si_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; __trellis_si_arm"
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
fi
builtin unset __trellis_si_version
