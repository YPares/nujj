# nujj

A set of nushell utility functions wrapping the [`jj`](https://github.com/jj-vcs/jj) and [`gh`](https://github.com/cli/cli) CLI tools.

## Usage

Just import it within nushell.
E.g. `use <path_to_nujj_repo> *` in a nushell REPL to put all the modules into scope, with their subcommands.

You can add this `use` line to your `$HOME/.config/nushell/config.nu`
or to any autoloaded nushell script.

## Main features

- Getting the jj log as a structured nushell table
- Getting PRs lists from GitHub as structured nushell tables
- `jjiles`: an interactive `jj log` with `fzf` (à la [`jj-fzf`](https://github.com/tim-janik/jj-fzf)),
  with custom jj log templates support, auto-refresh, adaptive diff layout, system theme detection
  (which will also work in [WSL](https://learn.microsoft.com/en-us/windows/wsl/))
  and syntax-highlighting via [`delta`](https://github.com/dandavison/delta).
  Run `jjiles --help` for more info

## Dependencies

- nushell (nixpkgs#nushell)
- jj (nixpkgs#jujutsu)
- gh (nixpkgs#gh)
- fzf (nixpkgs#fzf)
- delta (nixpkgs#delta)
- fmt (nixpkgs#fmt)
