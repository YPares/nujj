use ./deltau.nu

def list-to-revset [] {
  let list = $in
  if ($list | is-empty) {
    "none()"
  } else {
    $"\(($list | str join '|'))"
  }
}

# Add/remove parent(s) to a change
export def --wrapped reparent [
  --revision (-r): string = "@"
  ...parents: string
] {
  let added = $parents | parse "+{rev}" | get rev
  let removed = $parents | parse "-{rev}" | get rev
 
  ( jj rebase -s $revision
       -d $"all:\(($revision)- | ($added | list-to-revset)) & ~($removed | list-to-revset)"
  )
}

# Select an operation and restore the working copy back to it
export def back [
  num_ops: number = 15
] {
  clear
  let op = (
    jj op log --no-graph -T 'id.short() ++ "\n" ++ description ++ "\n" ++ tags ++ "\n"' -n $num_ops |
    lines | chunks 3 |
    each {|chunk|
      {id: $chunk.0, desc: $"* ($chunk.1) (ansi purple)\n      [($chunk.2)](ansi reset)"}
    } |
    input list -f -d desc
  )
  jj op restore $op.id
}

export def restore-at [
  restoration_point: string
  --revision (-r): string = "@"
  --no-split (-S)
] {
  if not $no_split {
    jj new --no-edit -A $revision
  }
  jj restore --from $restoration_point --to $revision (if not $no_split { --restore-descendants } else {""})
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

  ( jj log ...(if $revset != null {[-r $revset]} else {[]})
       --no-graph
       -T $"($columns | str join $"++'(char fs)'++") ++ '(char rs)'"
  ) |
  str trim --right --char (char rs) |
  split row (char rs) |
  parse $parser |
  rename -c {change_id: index}
}

export def bookmarks-to-table [
  revset: string = "remote_bookmarks()"
] {
    tblog -r $revset bookmarks "author.name()" "author.timestamp()" |
    rename -c {author_name: author, author_timestamp: date} |
    update bookmarks {split row " " | parse "{branch}@{remote}"} | flatten --all |
    update date {into datetime}
}

# Commit and advance the branches
export def ci [
  --message (-m): string
] {
  jj commit ...(if $message != null {[-m $message]} else {[]})
  jj bookmark move --from @- --to @
}

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
  jj bookmark move $bookmark --to $"($bookmark)+"
}

def cat-args [] {
  each {|arg|
    if ($arg | str contains " ") {
      $"'($arg)'"
    } else {
      $arg      
    }
  } |
  str join ' '
}

# Shows the delta diff everytime a folder changes
export def watch-diff [folder] {
  let theme = deltau theme-flags-from-system
  watch $folder {
    clear
    ^jj diff --git | deltau auto-layout $theme
  }
}

const explore_script = [(path self | path dirname) "cat-jj-diff.nu"] | path join

# Uses fzf to show the jj log and to allow to drill into revisions
export def --wrapped tui [
  --watch (-w): path # Watch the given path and refresh fzf whenever it changes
  ...args # Extra JJ args
] {
  let template = $"'(char us)' ++ stringify\(commit_id.shortest\()) ++ '(char us)' ++ (jj config get templates.log)"

  let quoted_template = $'"($template)"'
  let reload_cmd = $"reload\(jj ($args | cat-args) --color always -T ($quoted_template))"

  let watcher_data = if ($watch != null) {
    let fzf_port = port
    let job_id = job spawn {
      watch $watch -q {
        http post $"http://localhost:($fzf_port)" $reload_cmd
      }
    }
    {fzf_port: $fzf_port, job_id: $job_id}
  } else {
    {}
  }

  try {
    jj ...$args --color always -T $template |
    ( fzf
      --ansi --layout reverse --style default --no-clear --no-sort --track
      --preview-window hidden,right,70%,wrap
      --preview $"nu ($explore_script) diff {} (deltau theme-flags-from-system)"
      ...(if ($watcher_data.fzf_port? != null) {[--listen $watcher_data.fzf_port]}
          else {[]})
      --delimiter (char us) --with-nth "1,3"
      --bind "ctrl-r:change-preview-window(bottom,90%|right,70%)+toggle-preview+toggle-preview" # force preview layout refreshing
      --bind "enter:toggle-preview"
      --bind "ctrl-d:preview-half-page-down"
      --bind "ctrl-u:preview-half-page-up"
      --bind "ctrl-e:preview-half-page-up"
      --bind "page-down:preview-page-down"
      --bind "page-up:preview-page-up"
      --bind "esc:cancel"
      --bind $"left:($reload_cmd)+clear-query"
      --bind $"right:reload\(nu ($explore_script) show-files {})+clear-query"
    )
  }

  if ($watcher_data.job_id? != null) {
    job kill $watcher_data.job_id
  }
}

# Wraps jj log in delta
export def --wrapped log [...args] {
  ^jj log -T builtin_log_detailed --no-graph --git ...$args |
  deltau auto-layout (deltau theme-flags-from-system)
}

# Wraps jj diff in delta
export def --wrapped diff [...args] {
  ^jj diff --git ...$args |
  deltau auto-layout (deltau theme-flags-from-system)
}
