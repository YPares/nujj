use ../deltau.nu
use parsing.nu

const jjiles_dir = path self | path dirname

const fzf_callbacks = $jjiles_dir | path join fzf-callbacks.nu

const default_config_file = $jjiles_dir | path join default-config.toml


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
  columns | each { split row "," } | flatten | each {str trim} | wrap key
}

def to-fzf-bindings []: record -> list<string> {
  transpose keys actions | each {|row|
    [--bind $"($row.keys):($row.actions | str join "+")"]
  } | flatten
}

def to-fzf-colors [mappings: record, theme: string]: record -> string {
  transpose elem color | each {|row|
    let map = $mappings | get -i $row.color 
    let color = if ($map != null) {
      $map | get -i $theme | default $map.default?
    } else {
      $row.color | str join ":"
    }
    if ($color != null) {
      $"($row.elem):($color)"
    }
  } | str join ","
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
# Each "line" of the oplog/revlog will therefore be seen by fzf as:
# `jj graph characters | change_or_op_id | commit_id? | user template (char gs)`
# with '|' representing (char us)
# Fzf can then only show fields 1 & 4 to the user (--with-nth) and we can reliably
# extract the data we need from the other fields
# 
# We terminate the template by (char gs) because JJ cannot deal with templates containing NULL
def mktemplate [...args] {
  $args |
    each {[$"'(char us)'" $in]} |
    flatten |
    append [$"'(char gs)'"] | 
    str join "++"
}

# Get the bits of JJ's config that jjiles need to work
def get-needed-config-from-jj [
  jj_config: record
] {
  let process = {
    let clr = $in
    match ($clr | parse "bright {color}") {
      [{color: $c}] => $"light_($c)"
      _ => $clr
    }
  }
  {
    revsets: {
      log: $jj_config.revsets.log
    }
    templates: {
      op_log: $jj_config.templates.op_log
      log: $jj_config.templates.log
    }
    colors: {
      operation: ($jj_config.colors."operation id" | do $process)
      revision: ($jj_config.colors.change_id.fg | do $process)
      commit: ($jj_config.colors.commit_id.fg | do $process)
    }
  }
}

# Get jjiles config
export def get-config [
  --jj-config (-j): record # Use this record as jj config instead of reading it from the files.
                           # Pass an empty record {} to get jjiles default config
] {
  let default_config = open $default_config_file
  let jj_config = if ($jj_config == null) {
    ^jj config list jjiles | from toml
  } else {$jj_config}
  $default_config | get jjiles | merge deep (
    $jj_config | get -i jjiles | default {}
  )
}

# # JJiles. A JJ Watcher.
#
# Shows an interactive and auto-updating jj log that allows you to drill down
# into revisions. By default, it will refresh everytime a jj command modifies
# the repository. Additionally, JJiles can be told to automatically snapshot
# the working copy and refresh upon changes to a local folder with --watch.
#
# # Main key bindings
#
# - Shift+right & left arrows: go into/out of a revision (to preview only
#   specific files)
# - Return: open/close the preview panel (showing the diff of a revision)
# - Ctrl+f or F3: toggle the search field on/off
# - Ctrl+r / Ctrl+b / Ctrl+t:
#   open the preview panel (showing the diff) at the right/bottom/top
#   (repeat to change the panel size)
# - Esc: close the preview panel or (if already closed) exit
# - Ctrl+c: empty search field or (if already empty) exit
# - Ctrl+q: exit and output infos about selected operation/revision/commit/file
#
# # Notes about using custom JJ log templates
#
# JJiles will expose to your JJ templates a few config values they can use via
# the `config(...)` jj template function: - `width`: will be set to the width
# of the terminal window running jj log - `desc-len`: will be set to half this
# width (as JJ template language does not support basic arithmetic for now),
# to give an acceptable size at which to truncate commit description headers.
#
# For example:
# `truncate_end(config("desc-len").as_integer(), description.first_line())`
#
# # User configuration
#
# JJiles UI, keybindings and colors can be configured via a `[jjiles]`
# section in your ~/.config/jj/config.toml.
#
# Run `jjiles get-config` to get the current config as a nushell record. See
# the `default-config.toml` file in this folder for more information.
export def --wrapped main [
  --help (-h) # Show this help page
  --revisions (-r): string # Which rev(s) to log
  --template (-T): string # The alias of the jj log template to use
  --at-operation: string
    # An operation (from 'jj op log') at which to browse your repo.
    # Will deactivate the .jj folder watching if given.
  --at-op: string # Alias for --at-operation (to match jj CLI args)
  --watch (-w): path # A folder to watch for changes. Cannot be used with --at-op(eration)
  --fetch-every (-f): duration # Regularly run jj git fetch
  --fuzzy # Use fuzzy finding instead of exact match
  ...args # Extra args to pass to 'jj log' (--config for example)
]: nothing -> record<change_or_op_id: string, commit_id?: string, file?: string> {
  # Will contain closures that release all the resources acquired so far:
  mut finalizers: list<closure> = []

  mut watched_files: list<path> = []

  let init_view = match $args {
    [op log] => {
      {view: "oplog", extra_args: []}
    }
    [op log ..$_rest] => {
      finalize $finalizers "Passing `jj op log` extra args is not supported"
    }
    [log ..$rest] => {
      {view: "revlog", extra_args: $rest}
    }
    _ => {
      {view: "revlog", extra_args: $args}
    }
  }

  let jj_cfg = ^jj config list --include-defaults | from toml
  let jjiles_cfg = get-config -j $jj_cfg
  let jj_cfg = get-needed-config-from-jj $jj_cfg

  # We retrieve the user revlog template:
  let revlog_template = if ($template == null) {
    $jj_cfg.templates.log
  } else {
    $template
  }
  # We retrieve the user default log revset:
  let revisions = if ($revisions == null) {
    $jj_cfg.revsets.log
  } else {
    $revisions
  }

  # We generate from the user oplog/revlog templates new templates
  # from which fzf can reliably extract the data it needs.
  let oplog_template = (
    mktemplate "id.short()" "''" $jj_cfg.templates.op_log
  )
  let revlog_template = (
    mktemplate "change_id.shortest(8)" "commit_id.shortest(8)" $revlog_template
  )
  
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
    diff_config: $jjiles_cfg.diff
    color_config: ($jj_cfg.colors | merge $jjiles_cfg.colors.elements)
    revset: $revisions
    is_evolog_shown: false
    current_view: $init_view.view
    pos_in_oplog: 0
    selected_operation_id: $operation
    pos_in_revlog: {} # indexed by operation_id
    selected_change_id: null
    pos_in_evolog: {} # indexed by change_id
    selected_commit_id: null
    pos_in_files: {} # indexed by commit_id
  } | save $state_file
  
  let fzf_port = port
  
  let back_keys = "shift-left,shift-tab,ctrl-h"
  let into_keys = "shift-right,tab,ctrl-l"
  let all_move_keys = $"shift-up,up,shift-down,down,($back_keys),($into_keys)"

  let on_load_started_commands = $"change-header\((ansi default_bold)...(ansi reset))+unbind\(($all_move_keys))"

  let repo_root = ^jj root
  let repo_jj_folder = $repo_root | path join ".jj"
  
  let jj_watcher_id = if ($freeze_at_op == null) {
    $watched_files = $repo_jj_folder | append $watched_files
    ^jj debug snapshot
    let id = job spawn {
      watch $repo_jj_folder -q {
        ( $"($on_load_started_commands)+(cmd update-list refresh $state_file "{n}" "{}")" |
            http post $"http://localhost:($fzf_port)"
        )
      }
    }
    $finalizers = {job kill $id} | append $finalizers
    $id
  }

  if ($watch != null) {
    if ($freeze_at_op != null) {
      finalize $finalizers "--watch cannot be used with --at-op(eration)"
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
  }

  if ($fetch_every != null) {
    let id = job spawn {loop {
      sleep $fetch_every
      ^jj git fetch
    }}
    $finalizers = {job kill $id} | append $finalizers
  }

  let theme = match (deltau theme-flags) {
    ["--dark"] => "dark"
    ["--light"] => "light"
    _ => "16"
  }

  let main_bindings = {
    shift-up: up
    shift-down: down
    ctrl-space: jump
    $back_keys: [
      $on_load_started_commands
      (cmd update-list back $state_file "{n}" "{}")
      clear-query
      ...(cond (not $jjiles_cfg.interface.search-bar-visible) hide-input)
    ]
    $into_keys: [
      $on_load_started_commands
      (cmd update-list into $state_file "{n}" "{}")
      clear-query
      ...(cond (not $jjiles_cfg.interface.search-bar-visible) hide-input)
    ]
    resize: [
      "execute(tput reset)" # Avoids glitches in the fzf interface when terminal is resized
      (cmd -c transform on-load-finished $state_file "{n}")  # Refresh the header
      refresh-preview
    ]
    load: [
      (cmd -c transform on-load-finished $state_file)
      $"rebind\(($all_move_keys))"
    ]
    
    ctrl-v: [
      $on_load_started_commands
      (cmd toggle-evolog $state_file "{n}" "{}")
    ]
    ctrl-r: [
      "change-preview-window(right,83%|right,50%)"
      show-header
      refresh-preview
    ]
    ctrl-b: [
      "change-preview-window(bottom,50%|bottom,93%)"
      (if ($jjiles_cfg.interface.menu-position == bottom) {"hide-header"} else {"show-header"})
      refresh-preview
    ]
    ctrl-t: [
      "change-preview-window(top,50%|top,93%)"
      (if ($jjiles_cfg.interface.menu-position == top) {"hide-header"} else {"show-header"})
      refresh-preview
    ]

    "ctrl-f,f3":     [clear-query, toggle-input]
    enter:           [toggle-preview, show-header]
    esc:             [close, show-header]
  }

  let conflicting_keys = $main_bindings | used-keys | join ($jjiles_cfg.bindings.fzf | used-keys) key
  if ($conflicting_keys | is-not-empty) {
    finalize $finalizers $"Keybindings for ($conflicting_keys | get key) cannot be overriden by user config"
  }

  open $state_file |
    update watched_files ($watched_files | path expand | path relative-to ("." | path expand)) |
    save -f $state_file

  let res = try {
    ^nu -n $fzf_callbacks update-list refresh $state_file |
    ( ^fzf
      --read0
      --delimiter (char us) --with-nth "1,4"
      --layout (match $jjiles_cfg.interface.menu-position {
        "top" => "reverse"
        "bottom" => "reverse-list"
      })
      --no-sort --track
      ...(cond (not $jjiles_cfg.interface.search-bar-visible) --no-input)
      ...(cond (not $fuzzy) --exact)

      --ansi --color $theme
      --style $jjiles_cfg.interface.fzf-style
      --color ($jjiles_cfg.colors.fzf | to-fzf-colors $jjiles_cfg.colors.theme-mappings $theme)
      --highlight-line
      --header-first
      --header-border  $jjiles_cfg.interface.borders.header 
      --input-border   $jjiles_cfg.interface.borders.input
      --list-border    $jjiles_cfg.interface.borders.list
      --preview-border $jjiles_cfg.interface.borders.preview
      --prompt "Filter: "
      --ghost "Ctrl+f: hide | Ctrl+p or n: navigate history"
      --info inline-right

      --preview-window "hidden,wrap"
      --preview ([nu -n $fzf_callbacks preview $state_file "{}"] | str join " ")

      --history ($repo_jj_folder | path join "jjiles_history")

      ...(cond ($jj_watcher_id != null) --listen $fzf_port)

      ...($main_bindings | merge $jjiles_cfg.bindings.fzf | to-fzf-bindings)
    )
  } catch {{error: $in}}
  ( finalize $finalizers
      (if (($res | describe) == record and
           $res.error? != null and
           $res.error.exit_code? != 130) {
           # fzf being Ctrl-C'd isn't an error for us. Thus we only rethrow other errors
        $res.error
      })
  )
  if ($res | describe) == string {
    $res | parsing get-matches | transpose k v | where v != "" | transpose -rd
  }
}
