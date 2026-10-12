import Foundation

/// Shell snippets that push when any interactive command runs longer than a threshold.
public enum ShellInit {
    static let ignored = "vim nvim vi nano emacs less more man top htop btop ssh mosh tmux screen claude watch tail fzf lazygit"

    public static func script(for shell: String, binary: String) -> String? {
        switch shell {
        case "zsh": return zsh(binary: binary)
        case "bash": return bash(binary: binary)
        default: return nil
        }
    }

    static func zsh(binary: String) -> String {
        """
        # rungrinh: push to your phone when a command runs longer than $RUNGRINH_MIN seconds.
        # Add to ~/.zshrc:  eval "$(rungrinh shell-init zsh)"
        zmodload zsh/datetime 2>/dev/null
        : ${RUNGRINH_MIN:=30}
        : ${RUNGRINH_IGNORE:="\(ignored)"}
        __rungrinh_preexec() { __rungrinh_cmd="$1"; __rungrinh_start=$EPOCHSECONDS; }
        __rungrinh_precmd() {
          local code=$?
          [[ -z "$__rungrinh_start" ]] && return
          local elapsed=$(( EPOCHSECONDS - __rungrinh_start ))
          local cmd="$__rungrinh_cmd"
          unset __rungrinh_start __rungrinh_cmd
          (( elapsed < RUNGRINH_MIN )) && return
          local first=${${(z)cmd}[1]}
          [[ " $RUNGRINH_IGNORE " == *" $first "* ]] && return
          "\(binary)" command-done --seconds "$elapsed" --exit "$code" -- "$cmd" >/dev/null 2>&1 &!
        }
        autoload -Uz add-zsh-hook
        add-zsh-hook preexec __rungrinh_preexec
        add-zsh-hook precmd __rungrinh_precmd
        """
    }

    static func bash(binary: String) -> String {
        """
        # rungrinh: push to your phone when a command runs longer than $RUNGRINH_MIN seconds.
        # Add to ~/.bashrc:  eval "$(rungrinh shell-init bash)"
        : ${RUNGRINH_MIN:=30}
        : ${RUNGRINH_IGNORE:="\(ignored)"}
        __rungrinh_preexec() {
          [[ -n "$COMP_LINE" || "$BASH_COMMAND" == "$PROMPT_COMMAND"* || "$BASH_COMMAND" == __rungrinh_* ]] && return
          [[ -z "$__rungrinh_start" ]] && { __rungrinh_cmd="$BASH_COMMAND"; __rungrinh_start=$SECONDS; }
        }
        __rungrinh_precmd() {
          local code=$?
          [[ -z "$__rungrinh_start" ]] && return
          local elapsed=$(( SECONDS - __rungrinh_start ))
          local cmd="$__rungrinh_cmd"
          unset __rungrinh_start __rungrinh_cmd
          (( elapsed < RUNGRINH_MIN )) && return
          local first=${cmd%% *}
          [[ " $RUNGRINH_IGNORE " == *" $first "* ]] && return
          ("\(binary)" command-done --seconds "$elapsed" --exit "$code" -- "$cmd" >/dev/null 2>&1 &)
        }
        trap '__rungrinh_preexec' DEBUG
        PROMPT_COMMAND="__rungrinh_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
        """
    }
}
