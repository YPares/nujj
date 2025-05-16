# nujj

A set of nushell utility functions wrapping the `jj` (Jujutsu) and `gh` (GitHub) CLI tools.

## Usage

Just import it within nushell.
E.g. `use <path_to_nujj_folder> *` in a nushell REPL to put `nujj` and `nugh` into scope, with their subcommands.

You can add this `use` line to your `$HOME/.config/nushell/config.nu`
or to any autoload nushell script.

## Main features

- Getting the jj log as a nushell table
- Getting the PRs list from GitHub as a nushell table
- Interactive jj log with fzf (à la [jj-fzf](https://github.com/tim-janik/jj-fzf))

## Dependencies

- nushell (nixpkgs#nushell)
- jj (nixpkgs#jujutsu)
- fzf (nixpkgs#fzf)
- delta (nixpkgs#delta)
- gh (nixpkgs#gh)
