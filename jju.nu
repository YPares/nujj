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
export def main [
  --revset (-r): string
  ...columns: string
] {
  let columns = if ($columns | is-empty) {
      [change_id description "author.name()" "author.timestamp()"]
    } else {
      $columns
    }
  let parser = $columns | each { $"{($in | to-group-name)}" } | str join (char fs)

  ( jj log ...(if $revset != null {[-r $revset]} else {[]})
       --no-graph
       -T $"($columns | str join $"++'(char fs)'++") ++ '(char rs)'"
  ) |
  str trim --right --char (char rs) |
  split row (char rs) |
  parse $parser
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
