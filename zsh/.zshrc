# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Path to local binaries
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"

# Initialize Homebrew tools
eval "$(cd ~ && /opt/homebrew/bin/brew shellenv)"

# Dotfiles root — resolves from the ~/.zshrc symlink install.sh creates.
DOTFILES_DIR="$(dirname $(readlink ~/.zshrc))/.."

# Completions shipped with the dotfiles (currently _dev). Must be on fpath
# before oh-my-zsh.sh runs compinit. Oh My Zsh records fpath in its completion
# dump and deletes the dump when fpath changes, so this needs no manual
# rm ~/.zcompdump on the first shell after installing.
fpath=("$DOTFILES_DIR/zsh/completions" $fpath)

ZSH_THEME="robbyrussell"

zstyle ':omz:update' mode auto      # update automatically without asking

COMPLETION_WAITING_DOTS="true"

plugins=(git)

source $ZSH/oh-my-zsh.sh

# Preferred editor for local and remote sessions
if [[ -n $SSH_CONNECTION ]]; then
  export EDITOR='vim'
else
  export EDITOR='nvim'
fi

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"
export PATH="$HOME/bin:$PATH"

# Dotfiles scripts (DOTFILES_DIR is set at the top, before fpath).
#
# A function, not an alias, because completion needs the name. zsh expands an
# alias before working out what to complete, so with `alias dev=.../dev.sh` the
# command word became the script path and zsh fell back to completing
# filenames -- the `#compdef dev` in zsh/completions/_dev never fired.
dev() { "$DOTFILES_DIR/scripts/dev.sh" "$@" }
