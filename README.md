THIS REPOSITORY IS ARCHIVED. `nujj` & `jjiles` have been moved to [`monurepo`](https://github.com/YPares/monurepo).

# nujj

A set of nushell utility functions wrapping the [`jj`](https://github.com/jj-vcs/jj) and [`gh`](https://github.com/cli/cli) CLI tools.

## Usage

Just import it within nushell.
E.g. `use <path_to_nujj_repo> *` in a nushell REPL to put all the modules into scope, with their subcommands.

You can add this `use` line to your `$HOME/.config/nushell/config.nu`
or to any autoloaded nushell script.

## Main features

- `jjiles`, a jj _Watcher_: an interactive `jj log` with `fzf` (à la [`jj-fzf`](https://github.com/tim-janik/jj-fzf)),
  with custom jj log templates support, auto-refresh, adaptive diff layout, system theme detection
  (which will also work in [WSL](https://learn.microsoft.com/en-us/windows/wsl/))
  and syntax-highlighting via [`delta`](https://github.com/dandavison/delta).
  Run `jjiles --help` for more info
- `nujj tblog`: get the jj log as a structured nushell table
- `nujj atomic`: run some arbitrary nu closure that performs a set of jj operations,
  and automatically rollback to the initial state if one fails
- `nujj cap-off` / `nujj rebase-caps`: speed up your [mega-merge workflow](https://ofcr.se/jujutsu-merge-workflow)
  with automated rebases and bookmark moves driven by simple tags in your revisions descriptions
- Autocompletion: change ids, bookmark names, etc. autocompletion is provided for most of the `nujj` commands
- `nugh prs`: Getting PRs lists from GitHub as structured nushell tables

## Dependencies

- nushell (nixpkgs#nushell) (>=0.103)
- jj (nixpkgs#jujutsu) (latest stable version preferably)
- gh (nixpkgs#gh)
- fzf (nixpkgs#fzf)
- delta (nixpkgs#delta)
- fmt (nixpkgs#fmt)
