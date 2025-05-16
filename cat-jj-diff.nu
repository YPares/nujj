def main [] {}

def with-match [line cls] {
  let change_id_parser = '(?<change_id>\b[k-z]+\b)'
  let file_parser = $"(char fs)\(?<file>.+)(char fs)"
  match ($line | parse -r $change_id_parser) {
    [$cim ..$rest] => {
      match ($line | parse -r $file_parser) {
        [$fm ..$rest] => {
          do $cls $cim.change_id $fm.file
        }
        _ => {
          do $cls $cim.change_id null
        }
      }
    }
    _ => {
      print $"(ansi yellow)-- Nothing to show --(ansi reset)"
    }
  }
}

def "main diff" [line] {
  with-match $line {|change_id file|
    print (
      ( jj log -r $change_id --no-graph --color always
          -T "description ++
              author ++ ' - ' ++ author.timestamp() ++ '\n' ++
              self.diff().files().len() ++ ' file(s) changed'"
      ) | lines | each {$">> ($in)"} | str join "\n"
    )
    let bookmarks = (
      jj log -r $"($change_id):: & \(bookmarks\() | remote_bookmarks\())"
      --no-graph -T 'bookmarks ++ " "' --color always
    ) | complete
    let bookmarks = $bookmarks.stdout | str trim
    if not ($bookmarks | is-empty) {
      print $">> In ($bookmarks)"
    }
    print ""
    ( jj diff -r $change_id --color always --context 0 #--git
        ...(if $file != null {[$file]} else {[]})
    ) #| delta --paging never -s --width 130
  }
}

def "main show-files" [line] {
  with-match $line {|change_id|
    ( jj log -r $change_id --no-graph
        -T $"self.diff\().files\().map\(|x|
              change_id.shortest\() ++ ' (char fs)' ++ x.path\() ++ '(char fs)'
            ).join\('\n')"
    )
  }
}
