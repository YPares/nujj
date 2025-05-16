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

#
# JJiles. A JJ Watcher.
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
# Key bindings:
# - Return: open/close the preview panel
# - Right & left arrows: go into/out of a revision (to preview only specific files)
# - Ctrl+r: switch between preview panel right & bottom positions
# - PageUp & PageDown: scroll through the preview panel (full page)
# - Ctrl+d & Ctrl+u: scroll through the preview panel (half page)
# 
export def --wrapped main [
  --help (-h) # Show this help page
  --template (-T): string # The alias of the jj log template to use
  --freeze-at-op (-f): string
    # An operation (from 'jj op log') at which to browse your repo.
    # Will deactivate the .jj folder watching if given.
  --watch (-w): path # The folder to watch for changes. Cannot be used with --freeze-at-op
  ...args # Extra jj args
] {
  if $help {
    help
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
    log_template: $template
    jj_extra_args: $args
    current_view: log
    operation: $operation
    pos_in_log: 0
    change_id: null
  } | save $state_file
  
  let fzf_port = port

  let jj_watcher_id = if ($freeze_at_op == null) {
    job spawn {
      watch $"(^jj root)/.jj" -q {
        ( cmd update-list refresh $state_file "{}" |
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

      --ansi --color $color --style default
      --border none --info right
      --header-border block --header-first
      --highlight-line

      --preview-window "right,border-left,70%,hidden"
      --preview ([nu -n $fzf_callbacks preview $state_file "{}"] | str join " ")

      ...(if ($jj_watcher_id != null) {[--listen $fzf_port]} else {[]})

      ...(to-fzf-bindings {

        left: [
          (cmd update-list back $state_file "{}")
          clear-query
        ]
        right: [
          (cmd update-list into $state_file "{}")
          clear-query
        ]
        load: (cmd -c transform on-load-finished $state_file)
        ctrl-r: [
          "change-preview-window(bottom,border-top,90%|right,border-left,70%)"
          toggle-header
          toggle-input
          toggle-preview
          toggle-preview
        ] # the double toggle is to force preview's refresh

        enter:           toggle-preview
        page-down:       preview-page-down
        page-up:         preview-page-up
        ctrl-d:          preview-half-page-down
        "ctrl-u,ctrl-e": preview-half-page-up
        esc:             cancel

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
