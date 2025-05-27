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
  for closure in $finalizers {
    do $closure
  }
  if ($exc != null) {
    let exc = if (($exc | describe) == "string") {{msg: $exc}} else {$exc}
    std log error $exc.msg
    error make $exc
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
def wrap-template [...args] {
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

def get-templates [jj_cfg jjiles_cfg] {
  {
    op_log: ($jjiles_cfg.templates.op_log? | default $jj_cfg.templates.op_log)
    rev_log: ($jjiles_cfg.templates.rev_log? | default $jj_cfg.templates.log)
    evo_log: ($jjiles_cfg.templates.evo_log? | default $jj_cfg.templates.log)
    rev_preview: $jjiles_cfg.templates.rev_preview?
    evo_preview: $jjiles_cfg.templates.evo_preview
    file_preview: $jjiles_cfg.templates.file_preview?
  }
}

# # JJiles. A JJ Watcher.
#
# Shows an interactive and auto-updating jj log that allows you to drill down
# into revisions. By default, it will refresh everytime a jj command modifies
# the repository. Additionally, JJiles can be told to automatically snapshot
# the working copy and refresh upon changes to a local folder with --watch.
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
  --template (-T): string # The alias of the jj log template to use. Will override
                          # the 'jjiles.templates.rev_log' if given
  --fuzzy # Use fuzzy finding instead of exact match
  --fetch-every (-f): duration # Regularly run jj git fetch
  --at-operation: string
    # An operation (from 'jj op log') at which to browse your repo.
    #
    # If given (even it is "@"), do not run any watcher process. The interface
    # won't update upon changes to the repository or the working copy, and
    # the "@" operation will remain frozen the whole time to the value its
    # has when jjiles starts
  --at-op: string # Alias for --at-operation (to match jj CLI args)
  ...args # Extra args to pass to 'jj log' (--config for example)
]: nothing -> record<change_or_op_id: string, commit_id?: string, file?: string> {
  # Will contain closures that release all the resources acquired so far:
  mut finalizers: list<closure> = []

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


  # We retrieve the user default log revset:
  let revisions = if ($revisions == null) {
    $jj_cfg.revsets.log
  } else {
    $revisions
  }

  # We retrieve the user-defined templates, and generate from them
  # new templates from which fzf can reliably extract the data it needs:
  let templates = get-templates $jj_cfg $jjiles_cfg |
    update rev_log {if ($template == null) {$in} else {$template}} |
    update op_log {wrap-template "id.short()" "''" $in} |
    update rev_log {wrap-template "change_id.shortest(8)" "commit_id.shortest(8)" $in} |
    update evo_log {wrap-template "change_id.shortest(8)" "commit_id.shortest(8)" $in}

  let at_operation = $at_operation | default $at_op
  let do_watch = $at_operation == null
  let at_operation = if $do_watch {"@"} else {
    ^jj op log --at-operation $at_operation --no-graph -n1 --template 'id.short()' 
  }

  let tmp_dir = mktemp --directory
  $finalizers = {rm -rf $tmp_dir; std log debug $"($tmp_dir) deleted"} | append $finalizers
  
  let state_file = [$tmp_dir state.nuon] | path join

  {
    show_keybindings: $jjiles_cfg.interface.show-keybindings
    is_watching: $do_watch
    templates: $templates
    jj_revlog_extra_args: $init_view.extra_args
    diff_config: $jjiles_cfg.diff
    color_config: ($jj_cfg.colors | merge $jjiles_cfg.colors.elements)
    revset: $revisions
    evolog_toggled_on: $jjiles_cfg.interface.evolog-toggled-on
    current_view: $init_view.view
    pos_in_oplog: 0
    selected_operation_id: $at_operation
    pos_in_revlog: {} # indexed by operation_id
    selected_change_id: null
    default_commit_id: null
    pos_in_evolog: {} # indexed by change_id
    selected_commit_id: null
    pos_in_files: {} # indexed by change_id or commit_id
  } | save $state_file
  std log debug $"($state_file) written"
  
  let fzf_port = port
  
  let back_keys = "shift-left,shift-tab,ctrl-h"
  let into_keys = "shift-right,tab,ctrl-l"
  let all_move_keys = $"shift-up,up,shift-down,down,($back_keys),($into_keys)"

  let on_load_started_commands = $"change-header\((ansi default_bold)...(ansi reset))+unbind\(($all_move_keys))"

  let repo_root = ^jj root | path expand -n
  let repo_jj_folder = $repo_root | path join ".jj"
  
  let jj_watcher_id = if $do_watch {
    ^jj debug snapshot
    let id = job spawn {
      std log debug $"Job (job id): Watching ($repo_jj_folder)"
      watch $repo_jj_folder -q {
        std log debug $"Job (job id): Changes to .jj detected"
        ( $"($on_load_started_commands)+(cmd update-list refresh $state_file "{n}" "{}")" |
            http post $"http://localhost:($fzf_port)"
        )
      }
    }
    $finalizers = {job kill $id; std log debug $"Job ($id) killed"} | append $finalizers
    $id
  }

  let watchers_witness = $repo_jj_folder | path join "jjiles_watching.nuon"
  let to_watch = $jjiles_cfg.watched? | default []
  if ($do_watch and not ($to_watch | is-empty)) {
    if ($watchers_witness | path exists) {
      let pid = open $watchers_witness
      std log debug $"Working copy watchers already started by another jjiles instance \(pid ($pid))"
    } else {
      $finalizers = {rm -f $watchers_witness; std log debug $"($watchers_witness) deleted"} | append $finalizers
      $nu.pid | save $watchers_witness
      std log debug $"($watchers_witness) created \(with pid ($nu.pid))"
      for w in $to_watch {
        let folder = $repo_root | path join $w.folder
        let pattern = $w.pattern? | default "**/*"
        if not ($folder | path exists) {
          ( finalize $finalizers
              $"Folder ($folder) defined in [[jiles.watched]] does not exist in the repository" )
        }
        let id = job spawn {
          std log debug $"Job (job id): Watching ($folder) for changes to ($pattern)"
          watch $folder --glob $pattern -q {|_op, path|
            std log debug $"Job (job id): Changes to ($path) detected"
            # Will update the .jj folder and therefore trigger the jj watcher:
            ^jj debug snapshot
          }
        }
        $finalizers = {job kill $id; std log debug $"Job ($id) killed"} | append $finalizers
      }
    }
  }

  if ($fetch_every != null) {
    let id = job spawn {
      std log debug $"Job (job id): Will run 'jj git fetch' every ($fetch_every)"
      loop {
        sleep $fetch_every
        ^jj git fetch
        std log debug $"Job (job id): Ran 'jj git fetch'"
      }
    }
    $finalizers = {job kill $id; std log debug $"Job ($id) killed"} | append $finalizers
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
      ...(cond (not $jjiles_cfg.interface.show-searchbar) hide-input)
    ]
    $into_keys: [
      $on_load_started_commands
      (cmd update-list into $state_file "{n}" "{}")
      clear-query
      ...(cond (not $jjiles_cfg.interface.show-searchbar) hide-input)
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
      "change-preview-window(right,68%|right,83%|right,50%)"
      show-header
      refresh-preview
    ]
    ctrl-b: [
      "change-preview-window(bottom,50%|bottom,75%|bottom,93%)"
      (if ($jjiles_cfg.interface.menu-position == bottom) {"hide-header"} else {"show-header"})
      refresh-preview
    ]
    ctrl-t: [
      "change-preview-window(top,50%|top,75%|top,93%)"
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
      ...(cond (not $jjiles_cfg.interface.show-searchbar) --no-input)
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
      ...(if $jjiles_cfg.interface.show-keybindings {
        [--ghost "Ctrl+f: hide | Ctrl+p or n: navigate history"]
      } else {[]})
      --info inline-right

      --preview-window ([
        hidden
        ...(if $jjiles_cfg.interface.preview-line-wrapping {[wrap]} else {[]})
      ] | str join ",")
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
