use std log
def split-and-cleanup-rev-ids [col_name] {
  update $col_name {
    str trim | split row " " | filter {is-not-empty} |
    str trim --right --char "*"
  } |
  flatten $col_name
}

# Used to autocomplete bookmark args
# Lists any bookmark name from the default log output
export def complete-local-bookmarks [] {
  (tblog -n
    {value: local_bookmarks
     description: $env.nujj-config.completion.description
    }
  ) | split-and-cleanup-rev-ids value
}

# Used to autocomplete revision args
# Lists anything that can be used to identify a revision from the default log output
export def complete-revision-ids [] {
  (tblog -n
    {value:
      "change_id.shortest() ++ ' ' ++ commit_id.shortest() ++ ' '
       ++ local_bookmarks ++ ' ' ++ remote_bookmarks"
     description: $env.nujj-config.completion.description
    }
  ) | split-and-cleanup-rev-ids value
}

# Used to autocomplete remote name args
export def complete-remotes [] {
  ^jj git remote list | lines |
    each {split row " " | {value: $in.0, description: $in.1}}
}

def to-col-name [] {
  str replace -ra "[()'\":,;|]" "" |
  str replace -ra '[\.\-\+\s]' "_"
}

# Get the jj log as a table
# 
# The output table will contain first the columns from anon_templates,
# then those from --named
export def tblog [
  --revset (-r): string@complete-revision-ids  # Which revisions to log
  --color (-c)  # Keep JJ colors in output values
  --named (-n): record = {}
    # A record of templates, each entry corresponding to a column in the output table
  ...anon_templates: string
    # Anynonymous templates whose names in the output table will be derived from the templates' contents themselves
]: nothing -> table {
  let templates = if (($named | is-empty) and ($anon_templates | is-empty)) {
      $env.nujj-config.tblog.default | transpose column template
    } else {
      $anon_templates | each {{column: ($in | to-col-name), template: $in}} |
        append ($named | transpose column template)
    }

  (^jj log
    ...(if $revset != null {[-r $revset]} else {[]})
    ...(if $color {[--color always]} else {[]})
    --no-graph
    --template
      $"($templates | get template | str join $"++'(char fs)'++") ++ '(char rs)'"
  ) |
    split row (char rs) |
    each {|row|
      if ($row | str trim | is-not-empty) {
        $row | split row (char fs) |
          zip ($templates | get column) |
          each {{k: $in.1, v: $in.0}} | transpose -rd
      }
    }
}

# Run a set of jj operations as atomically as possible, ie. if one fails,
# revert back to the original state.
#
# However, this is not a real DB-like transaction, because it is not isolated:
# if you run other jj commands in parallel they can get intertwined with
# those of the closure (and the effect of those parallel operations would
# be cancelled along if the closure fails, which is probably what you want
# anyway in such a case)
#
# Long story short: don't run several of these in parallel, please.
#
# Also, it doesn't make them atomic with respect to 'jj undo', which will
# still only undo the last operation done by the closure. This is why we
# print the 'jj op restore' command to run to undo if the closure succeeded.
#
# Calls to 'atomic' can be nested, in which case the inner calls will just
# be no-ops.
export def atomic [
  --name (-n): string = "anonymous-atomic"
    # A name to show in the nushell logs
  closure: closure
    # A set of jj operations to run atomically
] {
  if ($env.nujj?.atomic-ongoing? == true) {
    log debug $"($name): Already in an atomic block"
    $in | do $closure
  } else {
    let init_op = ^jj op log --no-graph -n1 -T "id.short()" 
    let res = try {
      log debug $"($name): Starting atomic block at op ($init_op)"
      let res = $in | do {
        $env.nujj.atomic-ongoing = true
        $in | do $closure
      }
      let final_op = ^jj op log --no-graph -n1 -T "id.short()" 
      if $final_op == $init_op {
        log debug $"($name): Atomic block finished. Remained at op ($init_op)"
      } else {
        log debug $"($name): Atomic block finished. Now at op ($final_op)"
        log info $"($name): Several jj commands ran. To undo, use '(ansi yellow)jj op restore ($init_op)(ansi reset)'"
      }
      {ok: $res}
    } catch {|exc|
      log error $"($name): Atomic block failed. Reverting to op ($init_op)"
      ^jj op restore $init_op
      {exc: $exc}
    }
    match $res {
      {ok: $x} => { $x }
      {exc: $exc} => { error make $exc.raw }
    }
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
  --revision (-r): string@complete-revision-ids = "@" # The rev to rebase
  ...parents: string@complete-revision-ids # A set of parents each prefixed with '-' or '+'
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

# Rebases all revisions tagged with "<base:TARGET_BOOKMARK>" (in their description's first line)
# and advances each TARGET_BOOKMARK
export def sync-bases [
  --fetch (-f): string@complete-remotes
    # Additionally run 'jj git fetch' on the given remote on the base bookmarks
] {
  let bases = tblog --color -r 'subject(glob:"<base:*>")' -n {
    colored_change_id: "change_id.shortest(8)"
    subject: "description.first_line()"
  } | insert change_id {get colored_change_id | ansi strip} |
      insert bookmark {get subject | parse "<base:{bm}>" | get $.0.bm}
  atomic {
    if $fetch != null and ($bases | length) > 0 {
      print $">> Fetching ($bases.bookmark | each {[(ansi magenta) $in (ansi reset)] | str join ''} | str join ', ') from ($fetch):"
      ^jj git fetch --remote $fetch ...($bases.bookmark | each {[--branch $in]} | flatten)
    }
    for base in $bases {
      let bookmark_exists = (tblog -r $"present\(($base.bookmark))" change_id | length) > 0
      if $bookmark_exists {
        let between = tblog -r $"present\(($base.bookmark)):: & ($base.change_id)-" change_id
        if ($between | length) == 0 {
          # $bookmark diverged from $base, we rebase $base:
          print $">> Rebasing ($base.colored_change_id) onto (ansi magenta)($base.bookmark)(ansi reset):"
          ^jj rebase -b $base.change_id -d $base.bookmark
        }
      }
      print $">> Setting (ansi magenta)($base.bookmark)(ansi reset):"
      ^jj bookmark set $base.bookmark -r $"($base.change_id)-"
    }
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
  --revision (-r): string@complete-revision-ids = "@" # Which rev to split
  --no-split (-S) # Drop every change that came after restoration_point instead of splitting
] {
  atomic {
    if not $no_split {
      ^jj new --no-edit -A $revision
    }
    ^jj restore --from $restoration_point --to $revision (if not $no_split { --restore-descendants } else {""})
  }
}

# Return the bookmarks in some revset as a nushell table
export def bookmarks-to-table [
  revset: string@complete-revision-ids = "remote_bookmarks()"
] {
    tblog -r $revset bookmarks -n {author: "author.name()", date: "author.timestamp()"} |
    update bookmarks {split row " " | parse "{bookmark}@{remote}"} | flatten --all |
    update date {into datetime}
}

# Move a bookmark to the next commit
export def advance [
  bookmark: string@complete-local-bookmarks
] {
  ^jj bookmark move $bookmark --to $"($bookmark)+"
}
