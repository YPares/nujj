def mklink [
  text: string
  url: string
] {
  $url | ansi link --text $"(ansi blue)($text)(ansi reset)"
}

def defaults [...vals] {
  let cur = $in
  match $vals {
    [] => $cur
    [$x ..$xs] => {
      $cur | default --empty $x | defaults ...$xs
    }
  }
}

# Get a table of the PRs
export def --wrapped prs [
  --help (-h) # Show this help page
  ...args # Arguments to pass to `gh pr ls`
] {
  ^gh pr ls ...$args --json "number,title,url,headRefName,baseRefName,author,isDraft,statusCheckRollup" |
  from json |
  update author {get login} |
  update statusCheckRollup {
    each {|stat|
      let concl = mklink ($stat.conclusion | defaults $stat.status "(unknown)") $stat.detailsUrl
      {key: $stat.workflowName, val: $concl}
    } | transpose -rd
  } |
  update title {|pr|
    let draft = if $pr.isDraft {"Draft: "} else {""}
    mklink $"($draft)($pr.title)" $pr.url
  } |
  reject isDraft url |
  rename -c {number: index, headRefName: source, baseRefName: target, statusCheckRollup: status} |
  move --first title status author source target
}
