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

    # .zshrc runs after this file; move the hooks last on the first prompt so a
    # theme that rewrites the hook arrays cannot drop them.
    __trellis_si_deferred() {
        emulate -L zsh
        precmd_functions=(${precmd_functions:#__trellis_si_deferred})
        precmd_functions=(${precmd_functions:#__trellis_si_precmd} __trellis_si_precmd)
        preexec_functions=(${preexec_functions:#__trellis_si_preexec} __trellis_si_preexec)
        __trellis_si_precmd
    }
    typeset -ga precmd_functions preexec_functions
    precmd_functions+=(__trellis_si_deferred)
fi
unset __trellis_si_version
