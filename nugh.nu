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
  ^gh pr ls ...$args --json "number,title,url,headRefName,headRefOid,baseRefName,author,isDraft,statusCheckRollup" |
  from json | default [] |
  update author {get login} |
  update statusCheckRollup {
    each {|stat|
      let concl = mklink ($stat.conclusion | defaults $stat.status "(unknown)") $stat.detailsUrl
      {workflowName: $stat.workflowName, conclusion: $concl}
    }
  } |
  update title {|pr|
    let draft = if $pr.isDraft {"Draft: "} else {""}
    mklink $"($draft)($pr.title)" $pr.url
  } |
  reject isDraft url |
  rename -c {number: index, headRefName: sourceBranch, headRefOid: sourceCommit, baseRefName: targetBranch, statusCheckRollup: status} |
  move --first title status author sourceBranch targetBranch
}

export def ci-statuses [] {
  let list = prs | select sourceCommit status | insert group {
    let stats = $in.status | get conclusion | ansi strip | uniq
    if ($stats | any {$in == "FAILURE"}) {"ci-failure"
    } else if ($stats | all {$in == "SUCCESS"}) {"ci-success"
    } else {"ci-pending"}
  }
  match $list {
    [] => {
      {}
    }
    _ => {
      $list | group-by group --to-table | update items {get sourceCommit} | transpose -rd
    }
  }
}
