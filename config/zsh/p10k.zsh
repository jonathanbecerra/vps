theme_file="${XDG_DATA_HOME:-$HOME/.local/share}/zsh/catppuccin-powerlevel10k-themes/themes/.p10k-rainbow-catppuccin-mocha.zsh"
[[ ! -r $theme_file ]] || source "$theme_file"
typeset -g POWERLEVEL9K_CONFIG_FILE="${ZDOTDIR:-$HOME}/.p10k.zsh"
