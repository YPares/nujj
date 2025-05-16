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

def "main diff" [operation line] {
  let width = tput cols | into int

  with-match $line {|commit_id file|
    if ($operation != "@") {
      print $">> (ansi yellow)At operation: ($operation)(ansi reset)"
    }
    print (
      ( ^jj log -r $commit_id --no-graph --color always
          -T "description ++
              change_id.shortest(8) ++ ' (' ++ commit_id.shortest(8) ++ '); ' ++
              author ++ '; ' ++ author.timestamp() ++ '\n' ++
              diff.files().len() ++ ' file(s) modified'"
          --ignore-working-copy
          --at-operation $operation
      ) | lines | each {$">> ($in)"} | str join "\n"
    )
    let bookmarks = (
      ^jj log -r $"($commit_id):: & \(bookmarks\() | remote_bookmarks\())"
        --no-graph -T 'bookmarks ++ " "' --color always
        --ignore-working-copy
        --at-operation $operation
    ) | complete
    let bookmarks = $bookmarks.stdout | str trim
    if not ($bookmarks | is-empty) {
      print $">> In ($bookmarks)"
    }
    print ""
    ( ^jj diff -r $commit_id --color always --git
        ...(if $file != null {[$file]} else {[]})
        --ignore-working-copy
        --at-operation $operation
    ) | deltau wrapper --paging never 
  }
}

def "main show-files" [operation line] {
  with-match $line {|commit_id|
    ( ^jj log -r $commit_id --no-graph
        -T $"self.diff\().files\().map\(|x|
              '(char us)' ++ commit_id.shortest\() ++ '(char us)(char fs)' ++ x.path\() ++ '(char fs)'
            ).join\('(char gs)')"
        --ignore-working-copy
        --at-operation $operation
    ) | tr (char gs) '\0'
  }
}
