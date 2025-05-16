# nujj

A set of nushell utility functions wrapping the `jj` and `gh` CLI tools.

## Usage

Just import it within nushell.
E.g. `use <path_to_nujj_folder> *` in a nushell REPL to put `nujj` and `nugh` into scope, with their subcommands.

You can add this `use` line to your `$HOME/.config/nushell/config.nu`
or to any autoload nushell script.

## Features

- Getting jj log as structured nushell tables
- Getting PRs from GitHub as structured nushell tables
- Interactive jj log with fzf

## Dependencies

- nushell (nixpkgs#nushell)
- jj (nixpkgs#jujutsu)
- fzf (nixpkgs#fzf)
- delta (nixpkgs#delta)
- gh (nixpkgs#gh)
