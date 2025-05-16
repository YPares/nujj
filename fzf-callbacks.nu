use ./deltau.nu

def main [] {}

def with-match [line cls] {
  let commit_id_parser = $"(char us)\(?<commit_id>.+)(char us)"
  let file_parser = $"(char fs)\(?<file>.+)(char fs)"

  match ($line | parse -r $commit_id_parser) {
    [$cim ..$rest] => {
      match ($line | parse -r $file_parser) {
        [$fm ..$rest] => {
          do $cls $cim.commit_id $fm.file
        }
        _ => {
          do $cls $cim.commit_id null
        }
      }
    }
    _ => {
      print $"(ansi yellow)-- Nothing to show --(ansi reset)"
    }
  }
}

def print-log [state] {
  let width = tput cols | into int | $in / 2 | into int

  ( ^jj ...$state.jj_extra_args
        --color always
        --template $state.log_template
        --config $"desc-len=($width)"
        --ignore-working-copy
        --at-operation $state.operation
  ) |
  str replace -ra $"\\s*(char gs)\\s*" (char gs) |
  tr (char gs) "\\0"
}

def print-commit-files [state fzf_line_contents] {
  with-match $fzf_line_contents {|commit_id|
    ( ^jj log -r $commit_id --no-graph
        -T $"self.diff\().files\().map\(|x|
              '(char us)' ++ commit_id.shortest\() ++ '(char us)(char fs)' ++ x.path\() ++ '(char fs)'
            ).join\('(char gs)')"
        --ignore-working-copy
        --at-operation $state.operation
    ) | tr (char gs) '\0'
  }
}

def "main update-view" [transition state_file fzf_line_num fzf_line_contents] {
  mut state = open $state_file

  match [$state.current_view $transition] {
    [log into] => {
      $state = $state |
        update pos-in-log ($fzf_line_num + 1)
      let jj_out = print-commit-files $state $fzf_line_contents | complete
      if ($jj_out.stdout | is-empty) {
        print-log $state  # The revision is empty, we stay where we are
      } else {
        $state = $state | update current_view files
        print $jj_out.stdout
      }
    }
    [files back] => {
      $state = $state | (update current_view log)
      print-log $state
    }
    [log _] => {
      print-log $state
    }
    [files _] => {
      print-commit-files $state $fzf_line_contents
    }
  }

  $state | save -f $state_file
}

def "main preview" [state_file fzf_line_num fzf_line_contents] {
  let state = open $state_file
  let width = tput cols | into int

  with-match $fzf_line_contents {|commit_id file|
    if ($state.operation != "@") {
      print $">> (ansi yellow)At operation: ($state.operation)(ansi reset)"
    }
    print (
      ( ^jj log -r $commit_id --no-graph --color always
          -T "description ++
              change_id.shortest(8) ++ ' (' ++ commit_id.shortest(8) ++ '); ' ++
              author ++ '; ' ++ author.timestamp() ++ '\n' ++
              diff.files().len() ++ ' file(s) modified'"
          --ignore-working-copy
          --at-operation $state.operation
      ) | lines | each {$">> ($in)"} | str join "\n"
    )
    let bookmarks = (
      ^jj log -r $"($commit_id):: & \(bookmarks\() | remote_bookmarks\())"
        --no-graph -T 'bookmarks ++ " "' --color always
        --ignore-working-copy
        --at-operation $state.operation
    ) | complete
    let bookmarks = $bookmarks.stdout | str trim
    if not ($bookmarks | is-empty) {
      print $">> In ($bookmarks)"
    }
    print ""
    ( ^jj diff -r $commit_id --color always --git
        ...(if $file != null {[$file]} else {[]})
        --ignore-working-copy
        --at-operation $state.operation
    ) | deltau wrapper --paging never 
  }
}

def "main on-load-finished" [state_file] {
  let state = open $state_file

  match $state.current_view {
    "log" => {
      print $"pos\(($state.pos-in-log))"
    }
    _ => {
      print "pos(0)"
    }
  }
}
