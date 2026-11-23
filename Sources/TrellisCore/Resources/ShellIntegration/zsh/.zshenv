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
# The prompt chosen in Settings (FR-SI10); empty leaves the user's prompt alone.
typeset -g __trellis_si_prompt_preset="${TRELLIS_PROMPT_PRESET-}"
unset TRELLIS_PROMPT_PRESET

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

    # The checked-out branch, or a short commit when detached, into REPLY. Reads .git/HEAD itself: running git
    # before every prompt is slow, and macOS's /usr/bin/git stub offers to install the developer tools.
    __trellis_si_git_branch() {
        emulate -L zsh
        REPLY=
        local d="$PWD" g line head
        while [[ ! -e "$d/.git" ]]; do
            [[ "$d" == / || -z "$d" ]] && return 1
            d="${d:h}"
        done
        g="$d/.git"
        if [[ -f "$g" ]]; then
            [[ -r "$g" ]] && IFS= read -r line < "$g"
            [[ "$line" == "gitdir: "* ]] || return 1
            g="${line#gitdir: }"
            [[ "$g" == /* ]] || g="$d/$g"
        fi
        # A regular file only: a FIFO or device named HEAD in an unpacked archive would block every prompt.
        [[ -f "$g/HEAD" && -r "$g/HEAD" ]] && IFS= read -r head < "$g/HEAD"
        case "$head" in
            "ref: refs/heads/"*) REPLY="${head#ref: refs/heads/}" ;;
            "ref: "*) REPLY="${head#ref: }" ;;
            *) REPLY="${head[1,7]}" ;;
        esac
        [[ -n "$REPLY" ]]
    }

    # Builds PS1 for the chosen preset (FR-SI10) from the status saved by __trellis_si_prompt. The directory comes
    # from %~ and %1~, and the branch is %-escaped and, under prompt_subst, only referenced, so a directory or branch
    # name can never run code or inject prompt sequences. prompt_subst is checked here, right before each drawing.
    __trellis_si_prompt_build() {
        local subst=
        [[ -o prompt_subst ]] && subst=1
        emulate -L zsh
        local -i ret=${__trellis_si_prompt_status:-0}
        local ok='%F{2}' branch= REPLY
        (( ret == 0 )) || ok='%F{1}'
        local arrow="%B$ok❯%f%b"
        if [[ "$__trellis_si_prompt_preset" == (git|twoLine) ]] && __trellis_si_git_branch; then
            # %~ shows control characters as ^X; the branch, read from a file, gets `?` so it can't send escape sequences.
            REPLY="${REPLY//[[:cntrl:]]/?}"
            typeset -g __trellis_si_prompt_branch="${REPLY//\%/%%}"
            if [[ -n "$subst" ]]; then branch=' %F{5}(${__trellis_si_prompt_branch})%f'; else branch=" %F{5}(${__trellis_si_prompt_branch})%f"; fi
        fi
        case "$__trellis_si_prompt_preset" in
            minimal) PS1="$arrow " ;;
            classic) PS1='%B%F{2}%n@%m%f%b:%B%F{4}%~%f%b$ ' ;;
            directory) PS1="%F{6}%~%f $arrow " ;;
            compact) PS1="%B%F{4}%1~%f%b $arrow " ;;
            git) PS1="%F{6}%~%f$branch $arrow " ;;
            twoLine) PS1="%F{8}╭─ %f%F{2}%n@%m%f %B%F{4}%~%f%b$branch"$'\n'"%F{8}╰─%f$arrow " ;;
            status)
                if (( ret == 0 )); then PS1='%F{2}✔%f'; else PS1="%B%F{1}✘ $ret%f%b"; fi
                PS1="$PS1 %F{6}%~%f ❯ "
                ;;
            clock) PS1="%F{8}[%D{%H:%M}]%f %F{6}%~%f $arrow " ;;
            lambda) PS1="%B%F{3}λ%f%b %F{4}%1~%f %B$ok→%f%b " ;;
            bracketed) PS1='[%F{2}%n@%m%f %F{4}%1~%f]$ ' ;;
        esac
        # The B mark stays last; what was built is remembered so a theme's later change can be noticed.
        PS1="$PS1"$'%{\e]133;B\a%}'
        typeset -g __trellis_si_prompt_ps1="$PS1"
    }

    # Before each prompt: saves the last command's status, then builds the prompt.
    __trellis_si_prompt() {
        local -i ret=$?
        typeset -g __trellis_si_prompt_status=$ret
        __trellis_si_prompt_build
        return ret
    }

    # A theme such as powerlevel10k keeps its own precmd hook last and sets PS1 there, after ours. The line editor
    # starts after every precmd hook, so the preset is put back there and the prompt redrawn, only when it was replaced.
    __trellis_si_prompt_line_init() {
        [[ "$PS1" == "${__trellis_si_prompt_ps1-}" ]] && return 0
        __trellis_si_prompt_build
        zle .reset-prompt
    }

    case "$__trellis_si_prompt_preset" in
        minimal | classic | directory | compact | git | twoLine | status | clock | lambda | bracketed) ;;
        *) __trellis_si_prompt_preset= ;;
    esac

    # .zshrc runs after this file; move the hooks last on the first prompt so a
    # theme that rewrites the hook arrays cannot drop them. The prompt goes just
    # before the B mark, which must stay at the end of PS1.
    __trellis_si_deferred() {
        emulate -L zsh
        local -a preset=()
        [[ -n "$__trellis_si_prompt_preset" ]] && preset=(__trellis_si_prompt)
        precmd_functions=(${precmd_functions:#__trellis_si_deferred})
        precmd_functions=(${precmd_functions:#__trellis_si_(precmd|prompt)} $preset __trellis_si_precmd)
        preexec_functions=(${preexec_functions:#__trellis_si_preexec} __trellis_si_preexec)
        if [[ -n "$__trellis_si_agent_wiring" ]]; then __trellis_si_agent_define; fi
        if [[ -n "$__trellis_si_prompt_preset" ]]; then
            __trellis_si_prompt
            # add-zle-hook-widget keeps other line-init widgets, and powerlevel10k wraps it instead of replacing it.
            autoload -Uz add-zle-hook-widget 2>/dev/null && add-zle-hook-widget line-init __trellis_si_prompt_line_init 2>/dev/null
        fi
        __trellis_si_precmd
    }
    typeset -ga precmd_functions preexec_functions
    precmd_functions+=(__trellis_si_deferred)
fi
unset __trellis_si_version
