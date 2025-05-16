use ./deltau.nu

const fzf_callbacks = [(path self | path dirname) "fzf-callbacks.nu"] | path join

def to-fzf-bindings [dict] {
  $dict | transpose key vals | each {|x|
    [--bind $"($x.key):($x.vals | str join "+")"]
  } | flatten
}

def --wrapped cmd [
  --fzf-command (-c): string = "reload"
  ...args: string
]: nothing -> string {
  $"($fzf_command)\(nu -n ($fzf_callbacks) ($args | str join ' '))"
}

def lcond [bool list] {
  if $bool {$list} else {[]}
}

const default_config = {
  bindings: {
    fzf: {
      "esc,ctrl-c":     cancel
      scroll-up:        offset-up
      scroll-down:      offset-down
      "alt-down,alt-j": page-down
      "alt-up,alt-k":   page-up
      page-down:        preview-page-down
      page-up:          preview-page-up
      ctrl-d:           preview-half-page-down
      ctrl-u:           preview-half-page-up
    }
  }
}

# # JJiles. A JJ Watcher.
#
# Shows an interactive and auto-updating jj log that allows you to drill down into revisions.
# By default, it will refresh everytime a jj command modifies the repository.
#
# Extra positional args will be passed straight to jj.
# The first positional arg can be 'evolog', since 'jj log' and 'evolog' use the same
# templates and their outputs can be parsed by fzf in exactly the same manner.
# Other JJ subcommands are not supported, do not use them with this wrapper.
# 
# Additionally, JJiles can be told to automatically snapshot the working copy and refresh
# upon changes to a local folder with --watch.
#
# # Main key bindings
#
# - Right & left arrows: go into/out of a revision (to preview only specific files)
# - Return: open/close the preview panel (showing the diff of a revision)
# - Ctrl+f or F3: toggle the search field on/off
# - Ctrl+r: place the preview on the right (repeat to change preview window size)
# - Ctrl+b: put the preview on the bottom (repeat to change preview window size)
# - Ctrl+q: exit immediately
#
# Other key bindings are rebindable via the JJ config file (see --output-default-config)
#
# # Notes about using custom JJ log templates
# 
# JJiles will expose to your JJ templates a few config values they can use via the `config(...)` jj template function:
# - `width`: will be set to the width of the terminal window running jj log
# - `desc-len`: will be set to half this width (as JJ template language does not support basic arithmetic for now),
#   to give an acceptable size at which to truncate commit description headers:
#   `truncate_end(config("desc-len").as_integer(), description.first_line())`
#
# JJiles can be configured via a `[jjiles]` section in your ~/.config/jj/config.toml
# For now, only `[jjiles.bindings.fzf]` is used
export def --wrapped main [
  --help (-h) # Show this help page
  --revisions (-r): string # Which rev(s) to log
  --template (-T): string # The alias of the jj log template to use
  --freeze-at-op (-f): string
    # An operation (from 'jj op log') at which to browse your repo.
    # Will deactivate the .jj folder watching if given.
  --watch (-w): path # The folder to watch for changes. Cannot be used with --freeze-at-op
  --hide-search (-S) # The finder is hidden by default
  --fuzzy # Use fuzzy finding instead of exact match
  --output-default-config # Output the default config
  ...args # Extra jj args
] {
  if $output_default_config {
    return {jjiles: $default_config}
  }

  # We read the user config:
  let config = $default_config | merge deep (
    ^jj config list jjiles e> /dev/null | from toml | get -i jjiles | default {}
  )

  # We retrieve the user default log revset:
  let revisions = if ($revisions == null) {
    ^jj config get revsets.log
  } else {
    $revisions
  }

  # We retrieve the user template:
  let template = if ($template == null) {
    ^jj config get templates.log
  } else {
    $template
  }

  # We generate from it a new template from which fzf can reliably extract the
  # data it needs:
  let template = [
    $"'(char us)'" # (char us) will be treated as the fzf field delimiter.
                   # Each "line" of the log will therefore be seen by fzf as:
                   # graph characters | change_id | user log template (char gs)
                   # (with '|' representing (char us))
                   # so that fzf can only show fields 1 & 3 to the user and still
                   # extract the change_id
    "change_id.shortest(8)"
    $"'(char us)'"
    $template
    $"'(char gs)'" # We terminate the template by (char gs) because JJ cannot deal
                   # it seems with templates containing NULL
  ] | str join " ++ "

  let operation = match $freeze_at_op {
    null => "@"
    _ => {
      ^jj op log --at-operation $freeze_at_op --no-graph -n1 --template 'id.short()'
    }
  }

  let tmp_dir = mktemp --directory
  let state_file = [$tmp_dir state.nuon] | path join

  {
    revset: $revisions
    log_template: $template
    jj_log_extra_args: $args
    current_view: log
    selected_operation: $operation
    pos_in_rev_log: 0
    selected_change_id: null
  } | save $state_file
  
  let fzf_port = port

  let jj_watcher_id = if ($freeze_at_op == null) {
    job spawn {
      watch $"(^jj root)/.jj" -q {
        ( cmd update-list refresh $state_file "{n}" "{}" |
            http post $"http://localhost:($fzf_port)"
        )
      }
    }
  }

  let extra_watcher_id = if ($watch != null) {
    if ($freeze_at_op != null) {
      rm -rf $tmp_dir
      error make {msg: "--watch cannot be used with --freeze-at-op"}
    }
    if not ($watch | path exists) {
      job kill $jj_watcher_id
      rm -rf $tmp_dir
      error make {msg: $"--watch: ($watch) does not exist"}
    }
    job spawn {
      watch $watch -q {
        ^jj debug snapshot
        # Will update the .jj folder and therefore trigger the jj watcher
      }
    }
  }

  let color = match (deltau theme-flags) {
    ["--dark"] => "dark"
    ["--light"] => "light"
    _ => "16"
  }

  try {
    ^jj debug snapshot
  
    ^nu -n $fzf_callbacks update-list refresh $state_file |
    ( ^fzf
      --read0
      --delimiter (char us) --with-nth "1,3"
      --layout reverse --no-sort --track
      ...(lcond $hide_search [--no-input])
      ...(lcond (not $fuzzy) [--exact])

      --style minimal
      --ansi --color $color
      --highlight-line
      --header-border block --header-first
      --input-border bottom
      --prompt "Filter: " --ghost "(Ctrl+f to hide)"
      --info-command $'echo "($revisions) - $FZF_INFO"' --info inline-right
      --pointer "🡆" --color "pointer:cyan"

      --preview-window "right,50%,hidden,wrap"
      --preview ([nu -n $fzf_callbacks preview $state_file "{}"] | str join " ")

      ...(lcond ($jj_watcher_id != null) [--listen $fzf_port])

      ...(to-fzf-bindings {

        "left,ctrl-h": [
          (cmd update-list back $state_file "{n}" "{}")
          clear-query
          ...(lcond $hide_search [hide-input])
        ]
        "right,ctrl-l": [
          (cmd update-list into $state_file "{n}" "{}")
          clear-query
          ...(lcond $hide_search [hide-input])
        ]
        load: (cmd -c transform on-load-finished $state_file)
        ctrl-r: [
          "change-preview-window(right,80%|right,50%)"
          show-header
          refresh-preview
        ]
        ctrl-b: [
          "change-preview-window(bottom,50%|bottom,90%)"
          hide-header
          refresh-preview
        ]

        "ctrl-f,f3":     [clear-query, toggle-input]
        enter:           [toggle-preview, show-header]

        ...$config.bindings.fzf

      })
    )
  }

  if ($extra_watcher_id != null) {
    job kill $extra_watcher_id
  }

  if ($jj_watcher_id != null) {
    job kill $jj_watcher_id
  }

  rm -rf $tmp_dir
}
