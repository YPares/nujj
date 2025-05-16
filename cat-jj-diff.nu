def main [] {}

def with-match [line cls] {
  let commit_id_parser = '(?<commit_id>\b[k-z]+\b)'
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

def --wrapped "main diff" [line ...args] {
  let width = tput cols | into int

  with-match $line {|commit_id file|
    print (
      ( jj log -r $commit_id --no-graph --color always
          -T "description ++
              change_id.shortest(8) ++ ' (' ++ commit_id.shortest(8) ++ '); ' ++
              author ++ '; ' ++ author.timestamp() ++ '\n' ++
              self.diff().files().map(|f| f.path()).join(' ')"
      ) | lines | each {$">> ($in)"} | str join "\n"
    )
    let bookmarks = (
      jj log -r $"($commit_id):: & \(bookmarks\() | remote_bookmarks\())"
      --no-graph -T 'bookmarks ++ " "' --color always
    ) | complete
    let bookmarks = $bookmarks.stdout | str trim
    if not ($bookmarks | is-empty) {
      print $">> In ($bookmarks)"
    }
    print ""
    ( jj diff -r $commit_id --color always --git
        ...(if $file != null {[$file]} else {[]})
    ) | ^delta --paging never --width $width ...(if $width >= 100 {["--side-by-side"]} else {[]}) ...$args 
  }
}

def "main show-files" [line] {
  with-match $line {|commit_id|
    ( jj log -r $commit_id --no-graph
        -T $"self.diff\().files\().map\(|x|
              change_id.shortest\() ++ ' (char fs)' ++ x.path\() ++ '(char fs)'
            ).join\('\n')"
    )
  }
}
