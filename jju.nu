# Add a parent to a change
export def addp [
  --revision (-r): string = "@"
  ...parents: string
] {
  jj rebase -s $revision -d $"all:($revision)- | ($parents | str join ' | ')"
}

# Remove a parent from a change
export def rmp [
  --revision (-r): string = "@"
  ...parents: string
] {
  jj rebase -s $revision -d $"all:($revision)- & ~\(($parents | str join ' | '))"
}

# Select an operation and restore the working copy back to it
export def back [
  num_ops: number = 10
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
  let columns = $columns | each {
    match $in {
      "description" => "description.lines().join(';')"
      _ => $in
    }
  }
  let parser = $columns | each { $"{($in | to-group-name)}" } | str join (char rs)

  ( jj log ...(if $revset != null {[-r $revset]} else {[]})
       --no-graph
       -T $"($columns | str join $"++'(char rs)'++") ++ '\n'"
  ) |
  parse $parser
}

export def bookmarks-to-table [
  revset: string = "remote_bookmarks()"
] {
    main -r $revset bookmarks "author.name()" "author.timestamp()" |
    rename -c {author_name: author, author_timestamp: date} |
    update bookmarks {split row " " | parse "{branch}@{remote}"} | flatten --all |
    update date {into datetime}
}
