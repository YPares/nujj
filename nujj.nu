use ./deltau.nu

def list-to-revset [] {
  let list = $in
  if ($list | is-empty) {
    "none()"
  } else {
    $"\(($list | str join '|'))"
  }
}

# Add/remove parent(s) to a rev
export def --wrapped reparent [
  --revision (-r): string = "@"
  ...parents: string
] {
  let added = $parents | parse "+{rev}" | get rev
  let removed = $parents | parse "-{rev}" | get rev
 
  ( ^jj rebase -s $revision
       -d $"all:\(($revision)- | ($added | list-to-revset)) & ~($removed | list-to-revset)"
  )
}

# Open a picker to select an operation and restore the working copy back to it
export def back [
  num_ops: number = 15
] {
  clear
  let op = (
    ^jj op log --no-graph -T 'id.short() ++ "\n" ++ description ++ "\n" ++ tags ++ "\n"' -n $num_ops |
    lines | chunks 3 |
    each {|chunk|
      {id: $chunk.0, desc: $"* ($chunk.1) (ansi purple)\n      [($chunk.2)](ansi reset)"}
    } |
    input list -f -d desc
  )
  ^jj op restore $op.id
}

# Split a revision according to one of its past states (identified by a commit_id).
# Keeps the changes before or at that state in the revision,
# and splits the changes that came after in another rev
export def restore-at [
  restoration_point: string # The past commit to restore the revision at
  --revision (-r): string = "@" # Which rev to split
  --no-split (-S) # Drop every change that came after restoration_point instead of splitting
] {
  if not $no_split {
    ^jj new --no-edit -A $revision
  }
  ^jj restore --from $restoration_point --to $revision (if not $no_split { --restore-descendants } else {""})
}

def to-group-name [] {
  str replace -ra "[()'\":,;|]" "" |
  str replace -ra '[\.\-\s]' "_"
}

# Get the jj log as a table
export def tblog [
  --revset (-r): string
  ...columns: string
] {
  let columns = if ($columns | is-empty) {
      [change_id description "author.name()" "author.timestamp()"]
    } else {
      [change_id ...$columns]
    }
  let parser = $columns | each { $"{($in | to-group-name)}" } | str join (char fs)

  ( ^jj log ...(if $revset != null {[-r $revset]} else {[]})
       --no-graph
       -T $"($columns | str join $"++'(char fs)'++") ++ '(char rs)'"
  ) |
  str trim --right --char (char rs) |
  split row (char rs) |
  parse $parser |
  rename -c {change_id: index}
}

# Return the bookmarks in some revset as a nushell table
export def bookmarks-to-table [
  revset: string = "remote_bookmarks()"
] {
    tblog -r $revset bookmarks "author.name()" "author.timestamp()" |
    rename -c {author_name: author, author_timestamp: date} |
    update bookmarks {split row " " | parse "{bookmark}@{remote}"} | flatten --all |
    update date {into datetime}
}

# Commit and advance the bookmarks
export def ci [
  --message (-m): string
] {
  ^jj commit ...(if $message != null {[-m $message]} else {[]})
  ^jj bookmark move --from @- --to @
}

# Open a picker to select a bookmark and advance it to its children
export def adv [
  bookmark?: string
  --revset (-r): string = "trunk()::@"
] {
  let bookmark = if $bookmark != null {
    $bookmark
  } else {
    tblog -r $"($revset) & bookmarks\()" "local_bookmarks.map(|x| x.name())" |
    rename index b | get b | each {split row " "} | flatten | input list
  }
  ^jj bookmark move $bookmark --to $"($bookmark)+"
}

# Shows the delta diff everytime a folder changes
export def watch-diff [folder] {
  watch $folder {
    clear
    ^jj diff --git | deltau wrapper
  }
}

# Wraps jj diff in delta
export def --wrapped diff [...args] {
  ^jj diff --git ...$args |
  deltau wrapper
}

const fzf_callbacks = [(path self | path dirname) "fzf-callbacks.nu"] | path join

def fzf-bindings [dict] {
  $dict | transpose key vals | each {|x|
    [--bind $"($x.key):($x.vals | str join "+")"]
  } | flatten
}

# A JJ wrapper that uses fzf to show an interactive JJ log and to drill down into revisions
#
# Extra positional args will be passed straight to JJ.
# The first positional arg can be 'evolog', since 'jj log' and 'evolog' use the same
# templates and their outputs can be parsed by fzf in exactly the same manner.
# Other JJ subcommands are not supported, do not use them with this wrapper.
# 
# Can be told to automatically refresh upon local file changes with --watch.
#
# Key bindings:
# - Return: open/close the preview panel
# - Right & left arrows: go into/out of a revision (to preview only specific files)
# - Ctrl+r: switch between preview panel right & bottom positions
# - PageUp & PageDown: scroll through the preview panel (full page)
# - Ctrl+d & Ctrl+u: scroll through the preview panel (half page)
export def --wrapped log [
  --help (-h) # Show this help page
  --template (-T): string # The alias of the jj log template to use
  --freeze-at-op (-f): string
    # The operation at which to browse the repo (from 'jj op log').
    # If not given, will watch the changes in the .jj folder to always show an up-to-date log.
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
                   # graph characters | commit_id | user log template (char gs)
                   # (with '|' representing (char us))
                   # so that fzf can only show fields 1 & 3 to the user and still
                   # extract the commit_id
    "stringify(commit_id.shortest())"
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
    pos_in_log: 0
    operation: $operation
    jj_extra_args: $args
    log_template: $template
    current_view: log
  } | save $state_file
  
  let fzf_port = port

  let jj_watcher_id = if ($freeze_at_op == null) {
    job spawn {
      watch $"(^jj root)/.jj" -q {
        ( http post $"http://localhost:($fzf_port)"
            $"reload\(nu -n ($fzf_callbacks) update-list refresh ($state_file) {n} {})"
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
    ^nu -n $fzf_callbacks update-list refresh $state_file 0 " " |
    ( ^fzf
      --read0 --highlight-line
      --layout reverse --no-sort --track
      --ansi --color $color --style default 
      --border none --info right
      # --info-command $"nu -n ($fzf_callbacks) info ($state_file)"
      --preview-window "right,border-left,70%,hidden"
      --preview $"nu -n ($fzf_callbacks) preview ($state_file) {n} {}"
      ...(if ($jj_watcher_id != null) {[--listen $fzf_port]} else {[]})
      --delimiter (char us) --with-nth "1,3"
      ...(fzf-bindings {
        ctrl-r: [
          "change-preview-window(bottom,border-top,90%|right,border-left,70%)"
          toggle-preview
          toggle-preview
        ] # the double toggle is to force preview's refresh
        enter: toggle-preview
        page-down: preview-page-down
        page-up: preview-page-up
        ctrl-d: preview-half-page-down
        "ctrl-u,ctrl-e": preview-half-page-up
        esc: cancel
        left: [
          $"reload\(nu -n ($fzf_callbacks) update-list back ($state_file) {n} {})"
          clear-query
        ]
        right: [
          $"reload\(nu -n ($fzf_callbacks) update-list into ($state_file) {n} {})"
          clear-query
        ]
        load: $"transform\(nu -n ($fzf_callbacks) on-load-finished ($state_file))"
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

# See 'nujj log --help'
export def --wrapped main [
  --help (-h) # Show this help page
  --template (-T): string # The alias of the jj log template to use
  --freeze-at-op (-f): string
    # The operation at which to browse the repo (from 'jj op log').
    # If not given, will watch the changes in the .jj folder to always show an up-to-date log.
  --watch (-w): path # The folder to watch for changes. Cannot be used with --freeze-at-op
  ...args # Extra jj args
] {
  log ...(if $help {[--help]} else {[]}) --template $template --freeze-at-op $freeze_at_op --watch $watch ...$args
}
