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

const fzf_callbacks = [(path self | path dirname) "fzf-callbacks.nu"] | path join

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
#
# Important:
#
# - when using --watch, fzf will return back to the last revision you went into
#   (with 'right arrow') every time it refreshes, or to the first line of the log
#   if you did not go into any revision
# - passing arbitrary template expressions to --template is not supported,
#   please use only template aliases (for the standard JJ templates or
#   those defined in your JJ config.toml)
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

  let tmp_dir = mktemp --directory
  let pos_file = [$tmp_dir pos.txt] | path join
  let jj_cmd_file = [$tmp_dir jj_cmd.nu] | path join

  "pos(0)" | save -f $pos_file
  
  let operation = match $freeze_at_op {
    null => "@"
    _ => {
      ^jj op log --at-operation $freeze_at_op --no-graph -n1 --template 'id.short()'
    }
  }
  
  # We generate the command that calls jj and write it to a temp file
  # (because we will need to call it again in case of refreshes):
  let width = tput cols | into int | $in / 2 | into int
  [ ^jj ...$args
        --color always
        --template $template
        --config $"desc-len=($width)"
        # in case the template uses a 'desc-len' config value
        --ignore-working-copy
        --at-operation $operation "|"
    str replace $"'(char gs)\n'" $"'(char gs)'" -a "|"
    tr (char gs) "\\0" # We use tr because nushell's str replace deals badly with NULL
  ] | each {|x|
    if ($x | str contains " ") {
      $"\"($x)\""
    } else {
      $x
    }
  } |
  str join " " | save $jj_cmd_file

  let fzf_port = port

  let jj_watcher_id = if ($freeze_at_op == null) {
    job spawn {
      watch $"(^jj root)/.jj" -q {
        ( http post $"http://localhost:($fzf_port)"
            $"reload\(nu ($jj_cmd_file))"
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

  try {
    ^nu $jj_cmd_file |
    ( ^fzf
      --read0 --highlight-line
      --ansi --layout reverse --style default --no-sort --track
      --preview-window "hidden,right,70%,wrap"
      --preview $"nu ($fzf_callbacks) diff ($operation) {}"
      ...(if ($jj_watcher_id != null) {[--listen $fzf_port]} else {[]})
      --delimiter (char us) --with-nth "1,3"
      --bind "ctrl-r:change-preview-window(bottom,90%|right,70%)+toggle-preview+toggle-preview"
          # the double toggle is to force preview's refresh
      --bind "enter:toggle-preview"
      --bind "ctrl-d:preview-half-page-down"
      --bind "ctrl-u:preview-half-page-up"
      --bind "ctrl-e:preview-half-page-up"
      --bind "page-down:preview-page-down"
      --bind "page-up:preview-page-up"
      --bind "esc:cancel"
      --bind $"left:rebind\(right)+reload\(nu ($jj_cmd_file))+clear-query"
      --bind $"load:transform\(cat ($pos_file))"
      --bind $"right:unbind\(right)+execute\(echo 'pos\('$\(\({n} + 1))')' > ($pos_file))+reload\(nu ($fzf_callbacks) show-files ($operation) {})+clear-query"
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

# Wraps jj diff in delta
export def --wrapped diff [...args] {
  ^jj diff --git ...$args |
  deltau wrapper
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
