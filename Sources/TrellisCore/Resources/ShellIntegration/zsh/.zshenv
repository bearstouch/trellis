# Trellis shell integration for zsh (protocol v1).
# Trellis points ZDOTDIR here; restore the user's value before any user file loads.
if [[ -n "${TRELLIS_ZSH_ZDOTDIR+x}" ]]; then
    export ZDOTDIR="$TRELLIS_ZSH_ZDOTDIR"
    unset TRELLIS_ZSH_ZDOTDIR
else
    unset ZDOTDIR
fi

# The nonce authenticates marks; keep it unexported so child processes never see it.
typeset -g __trellis_si_nonce="${TRELLIS_SHELL_INTEGRATION_NONCE-}"
typeset -g __trellis_si_version="${TRELLIS_SHELL_INTEGRATION-}"
unset TRELLIS_SHELL_INTEGRATION_NONCE TRELLIS_SHELL_INTEGRATION
# The typed-agent hook channel (FR-AG18) reaches only the agents the functions below run.
typeset -g __trellis_si_agent_socket="${TRELLIS_AGENT_SOCKET-}" __trellis_si_agent_nonce="${TRELLIS_AGENT_NONCE-}"
typeset -g __trellis_si_agent_wiring="${TRELLIS_AGENT_WIRING-}"
unset TRELLIS_AGENT_SOCKET TRELLIS_AGENT_NONCE TRELLIS_AGENT_WIRING

# Source the user's .zshenv at top level so its typesets stay global.
typeset -g __trellis_si_zshenv="${ZDOTDIR:-$HOME}/.zshenv"
if [[ -r "$__trellis_si_zshenv" ]]; then
    builtin source "$__trellis_si_zshenv"
fi
unset __trellis_si_zshenv

if [[ -o interactive && -n "$__trellis_si_nonce" && "$__trellis_si_version" == 1 && -z "${__trellis_si_installed-}" ]]; then
    typeset -g __trellis_si_installed=1 __trellis_si_running=
    zmodload zsh/parameter 2>/dev/null

    # Percent-encodes $1 into REPLY so paths and commands cannot break the OSC frame.
    __trellis_si_encode() {
        emulate -L zsh
        setopt no_multibyte
        local LC_ALL=C s="$1" out= c hex
        local -i i
        for (( i = 1; i <= ${#s}; i++ )); do
            c="${s[i]}"
            case "$c" in
                [a-zA-Z0-9/._~-]) out+="$c" ;;
                *) builtin printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
            esac
        done
        REPLY="$out"
    }

    __trellis_si_precmd() {
        local -i ret=$?
        emulate -L zsh
        if [[ -n "$__trellis_si_running" ]]; then
            builtin print -rn -- $'\e]133;D;'"$ret;trellis=$__trellis_si_nonce"$'\a'
            __trellis_si_running=
        fi
        local REPLY
        __trellis_si_encode "$PWD"
        builtin print -rn -- $'\e]133;A;trellis='"$__trellis_si_nonce;cwd=$REPLY"$'\a'
        # B carries no nonce: PS1 may be exported, and B changes no Trellis state.
        local mark=$'%{\e]133;B\a%}'
        [[ "$PS1" == *"$mark" ]] || PS1="$PS1$mark"
        return ret
    }

    __trellis_si_preexec() {
        emulate -L zsh
        local REPLY
        __trellis_si_encode "${1[1,4096]}"
        builtin print -rn -- $'\e]133;C;trellis='"$__trellis_si_nonce;cmdline_url=$REPLY"$'\a'
        __trellis_si_running=1
    }

    # Runs a typed agent with Trellis's hook wiring (FR-AG18). A record is
    # `<executable>\t<count>\t<count environment words>\t<arguments>`.
    __trellis_si_agent() {
        emulate -L zsh
        local line= exe="$1"
        shift
        for line in "${(@f)__trellis_si_agent_wiring}"; do
            [[ "$line" == "$exe"$'\t'* ]] && break
            line=
        done
        local -a rec
        rec=("${(@ps:\t:)line}")
        if [[ -z "$line" || -z "$__trellis_si_agent_nonce" || "${rec[2]}" != <-> ]]; then
            command "$exe" "$@"
            return
        fi
        local -i n=${rec[2]}
        command env "TRELLIS_AGENT_SOCKET=$__trellis_si_agent_socket" "TRELLIS_AGENT_NONCE=$__trellis_si_agent_nonce" \
            "${(@)rec[3,2+n]}" "$exe" "${(@)rec[3+n,-1]}" "$@"
    }

    # After the user's files, so their own function or alias of the same name wins.
    __trellis_si_agent_define() {
        emulate -L zsh
        local line exe
        for line in "${(@f)__trellis_si_agent_wiring}"; do
            exe="${line%%$'\t'*}"
            [[ -n "$exe" && "$exe" != "$line" ]] || continue
            (( $+functions[$exe] || $+aliases[$exe] )) && continue
            functions[$exe]="__trellis_si_agent ${(q)exe} \"\$@\""
        done
    }

    # .zshrc runs after this file; move the hooks last on the first prompt so a
    # theme that rewrites the hook arrays cannot drop them.
    __trellis_si_deferred() {
        emulate -L zsh
        precmd_functions=(${precmd_functions:#__trellis_si_deferred})
        precmd_functions=(${precmd_functions:#__trellis_si_precmd} __trellis_si_precmd)
        preexec_functions=(${preexec_functions:#__trellis_si_preexec} __trellis_si_preexec)
        if [[ -n "$__trellis_si_agent_wiring" ]]; then __trellis_si_agent_define; fi
        __trellis_si_precmd
    }
    typeset -ga precmd_functions preexec_functions
    precmd_functions+=(__trellis_si_deferred)
fi
unset __trellis_si_version
