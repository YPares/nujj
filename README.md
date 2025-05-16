# nujj

A set of nushell utility functions wrapping the [`jj`](https://github.com/jj-vcs/jj) and [`gh`](https://github.com/cli/cli) CLI tools.

## Usage

Just import it within nushell.
E.g. `use <path_to_nujj_folder> *` in a nushell REPL to put `nujj` and `nugh` into scope, with their subcommands.

You can add this `use` line to your `$HOME/.config/nushell/config.nu`
or to any autoloaded nushell script.

## Main features

- Getting the jj log as a structured nushell table
- Getting PRs lists from GitHub as structured nushell tables
- Interactive jj log with fzf (à la [jj-fzf](https://github.com/tim-janik/jj-fzf)),
  with adaptive diff layout, system theme detection (including in [WSL](https://learn.microsoft.com/en-us/windows/wsl/)) and syntax-highlighting via [delta](https://github.com/dandavison/delta)

## Dependencies

- nushell (nixpkgs#nushell)
- jj (nixpkgs#jujutsu)
- fzf (nixpkgs#fzf)
- delta (nixpkgs#delta)
- gh (nixpkgs#gh)
