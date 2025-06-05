use ./deltau.nu

# Run a set of jj operations atomically:
# if one fails, revert back to the original state
#
# Note that this isn't a real DB-like transaction in the sense
# that it isn't isolated: if you run other jj commands in parallel
# they can get intertwined with those of the closure (and the effect
# of those parallel operations would be cancelled along if the closure
# fails, which is probably what you want anyway in such a case)
#
# Long story short: don't run several of these in parallel, please.
#
# Also, it doesn't make them atomic with respect to 'jj undo', which
# will still only undo the last operation done by the closure
export def atomic [closure] {
  let init_op = ^jj op log --no-graph -n1 -T "id.short()" 
  try {
    do $closure
    print $"(ansi yellow)Important:(ansi reset) To undo, run 'jj op restore ($init_op)'"
  } catch {|e|
    ^jj op restore $init_op
    error make $e
  }
}

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
  --help (-h)
  --revision (-r): string = "@" # The rev to rebase
  ...parents: string # A set of parents each prefixed with '-' or '+'
] {
  let added = $parents | parse "+{rev}" | get rev
  let removed = $parents | parse "-{rev}" | get rev
 
  ( ^jj rebase -s $revision
       -d $"all:\(($revision)- | ($added | list-to-revset)) & ~($removed | list-to-revset)"
  )
}

# Rebase the current revision somewhere and replace its previous position by a new one, which we edit
export def --wrapped kick [
  --help (-h)
  --message (-m): string # Change the message of the current revision at the same time
  ...rebase_args # Args to give to jj rebase
] {
  atomic {
    ^jj new -A "@"
    if ($message != null) {
      ^jj desc -m $message -r "@-"
    }
    ^jj rebase -r "@-" ...$rebase_args
  }
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
  atomic {
    if not $no_split {
      ^jj new --no-edit -A $revision
    }
    ^jj restore --from $restoration_point --to $revision (if not $no_split { --restore-descendants } else {""})
  }
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
  atomic {
    ^jj commit ...(if $message != null {[-m $message]} else {[]})
    ^jj bookmark move --from @- --to @
  }
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
  ^jj diff --git ...$args | deltau wrapper
}

