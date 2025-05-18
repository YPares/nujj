use ./deltau.nu

const fzf_callbacks = [(path self | path dirname) "fzf-callbacks.nu"] | path join

const default_config = {
  interface: {
    menu_position: top
  }
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

def --wrapped cond [bool ...flags] {
  if $bool {$flags} else {[]}
}

def --wrapped cmd [
  --fzf-command (-c): string = "reload"
  ...args: string
]: nothing -> string {
  $"($fzf_command)\(nu -n ($fzf_callbacks) ($args | str join ' '))"
}

def used-keys []: record -> table<key: string> {
  columns | each { split row "," } | flatten | wrap key
}

def to-fzf-bindings []: record -> list<string> {
  transpose keys actions | each {|row|
    [--bind $"($row.keys):($row.actions | str join "+")"]
  } | flatten
}

# Runs a list of finalizers and optionally (re)throws an exception
def finalize [finalizers: list<closure>, exc?] {
  for fin in $finalizers {
    do $fin
  }
  if ($exc != null) {
    error make (if (($exc | describe) == "string") {{msg: $exc}} else {$exc})
  }
}

# (char us) will be treated as the fzf field delimiter.
# 
# Eg. each "line" of the revlog will therefore be seen by fzf as:
# graph characters | change_id | user log template (char gs)
# (with '|' representing (char us))
# so that fzf can only show fields 1 & 3 to the user and still
# extract the change_id
# 
# We terminate the template by (char gs) because JJ cannot deal
# it seems with templates containing NULL
def mktemplate [...args] {
  $args |
    each {[$"'(char us)'" $in]} |
    flatten |
    append [$"'(char gs)'"] | 
    str join "++"
}

# # JJiles. A JJ Watcher.
#
# Shows an interactive and auto-updating jj log that allows you to drill down into revisions.
# By default, it will refresh everytime a jj command modifies the repository.
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
# Other key bindings are rebindable via the JJ config file (see --output-default-config).
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
export def --wrapped main [
  --help (-h) # Show this help page
  --revisions (-r): string # Which rev(s) to log
  --template (-T): string # The alias of the jj log template to use
  --at-operation: string
    # An operation (from 'jj op log') at which to browse your repo.
    # Will deactivate the .jj folder watching if given.
  --at-op: string # Alias for --at-operation (to match jj CLI args)
  --watch (-w): path # A folder to watch for changes. Cannot be used with --at-operation
  --hide-search (-S) # The search bar is hidden by default
  --fuzzy # Use fuzzy finding instead of exact match
  --output-default-config # Output the default config
  ...args # Extra args to pass to 'jj log'
] {
  if $output_default_config {
    return {jjiles: $default_config}
  }
  
  # Will contain closures that release all the resources acquired so far:
  mut finalizers: list<closure> = []

  mut watched_files: list<path> = []

  let init_view = match $args {
    [op log] => {
      {view: "oplog", extra_args: []}
    }
    [op log ..$_args] => {
      finalize $finalizers "Passing `jj op log` extra args is not supported"
    }
    [log ..$rest] => {
      {view: "revlog", extra_args: $rest}
    }
    _ => {
      {view: "revlog", extra_args: $args}
    }
  }

  # We read the user config:
  let config = $default_config | merge deep (
    ^jj config list jjiles e> /dev/null | from toml | get -i jjiles | default {}
  )

  # We retrieve the user op log template:
  let oplog_template = ^jj config get templates.op_log
  # We retrieve the user revlog template:
  let revlog_template = if ($template == null) {
    ^jj config get templates.log
  } else {
    $template
  }
  # We retrieve the user default log revset:
  let revisions = if ($revisions == null) {
    ^jj config get revsets.log
  } else {
    $revisions
  }

  # We generate from the user oplog/revlog templates new templates
  # from which fzf can reliably extract the data it needs.
  let oplog_template = mktemplate "id.short()" $oplog_template
  let revlog_template = mktemplate "change_id.shortest(8)" $revlog_template

  let freeze_at_op = $at_operation | default $at_op
  let operation = match $freeze_at_op {
    null => "@"
    _ => {
      ^jj op log --at-operation $freeze_at_op --no-graph -n1 --template 'id.short()'
    }
  }

  let tmp_dir = mktemp --directory
  $finalizers = {rm -rf $tmp_dir} | append $finalizers
  
  let state_file = [$tmp_dir state.nuon] | path join

  {
    watched_files: []
    oplog_template: $oplog_template
    revlog_template: $revlog_template
    jj_revlog_extra_args: $init_view.extra_args
    revset: $revisions
    current_view: $init_view.view
    pos_in_oplog: 0
    selected_operation_id: $operation
    pos_in_revlog: {} # indexed by operation_id
    selected_change_id: null
    pos_in_files: {} # indexed by change_id
  } | save $state_file
  
  let fzf_port = port
  
  let jj_watcher_id = if ($freeze_at_op == null) {
    let jj_folder = $"(^jj root)/.jj"
    $watched_files = $jj_folder | append $watched_files
    ^jj debug snapshot
    let id = job spawn {
      watch $jj_folder -q {
        ( cmd update-list refresh $state_file "{n}" "{}" |
            http post $"http://localhost:($fzf_port)"
        )
      }
    }
    $finalizers = {job kill $id} | append $finalizers
    $id
  }

  let extra_watcher_id = if ($watch != null) {
    if ($freeze_at_op != null) {
      finalize $finalizers "--watch cannot be used with --freeze-at-op"
    }
    if not ($watch | path exists) {
      finalize $finalizers $"--watch: ($watch) does not exist"
    }
    $watched_files = $watch | append $watched_files
    let id = job spawn {
      watch $watch -q {
        ^jj debug snapshot
        # Will update the .jj folder and therefore trigger the jj watcher
      }
    }
    $finalizers = {job kill $id} | append $finalizers
    $id
  }

  let color = match (deltau theme-flags) {
    ["--dark"] => "dark"
    ["--light"] => "light"
    _ => "16"
  }

  let main_bindings = {
    "left,ctrl-h": [
      (cmd update-list back $state_file "{n}" "{}")
      clear-query
      ...(cond $hide_search hide-input)
    ]
    "right,ctrl-l": [
      (cmd update-list into $state_file "{n}" "{}")
      clear-query
      ...(cond $hide_search hide-input)
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
  }

  let conflicting_keys = $main_bindings | used-keys | join ($config.bindings.fzf | used-keys) key
  if ($conflicting_keys | is-not-empty) {
    finalize $finalizers $"Keybindings for ($conflicting_keys | get key) cannot be overriden by user config"
  }

  open $state_file |
    update watched_files ($watched_files | path expand | path relative-to ("." | path expand)) |
    save -f $state_file

  let exc = try {
    ^nu -n $fzf_callbacks update-list refresh $state_file |
    ( ^fzf
      --read0
      --delimiter (char us) --with-nth "1,3"
      --layout (match $config.interface.menu_position {
        "top" => "reverse"
        "bottom" => "reverse-list"
      })
      --no-sort --track
      ...(cond $hide_search --no-input)
      ...(cond (not $fuzzy) --exact)

      --style minimal
      --ansi --color $color
      --highlight-line
      --header-border block --header-first
      --input-border (match $config.interface.menu_position {
        "top" => "bottom"
        "bottom" => "top"
      })
      --prompt "Filter: " --ghost "(Ctrl+f to hide)"
      --info-command $'echo "($revisions) - $FZF_INFO"' --info inline-right
      --pointer "🡆" --color "pointer:cyan"

      --preview-window "right,50%,hidden,wrap"
      --preview ([nu -n $fzf_callbacks preview $state_file "{}"] | str join " ")

      ...(cond ($jj_watcher_id != null) --listen $fzf_port)

      ...($main_bindings | merge $config.bindings.fzf | to-fzf-bindings)
    )
  } catch {$in}
  ( finalize $finalizers
      (if ($exc.exit_code? != 130) { $exc })
      # fzf being Ctrl-C'd isn't an error for us. Thus we only rethrow other errors
  )
}
