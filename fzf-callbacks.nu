# Used inside fzf by jjiles.nu

use ./deltau.nu

def main [] {}

def get-matches [
]: string -> record<commit_id?: string, file?: string> {
  let commit_id_parser = $"(char us)\(?<commit_id>.+)(char us)"
  let file_parser = $"(char fs)\(?<file>.+)(char fs)"

  let text = $in
  [
    ...($text | parse -r $commit_id_parser)
    ...($text | parse -r $file_parser)
  ] | into record
}

def print-log [width: int, state: record] {
  ( ^jj ...$state.jj_extra_args
      --color always
      --template $state.log_template
      --config $"desc-len=($width / 2 | into int)"
      --ignore-working-copy
      --at-operation $state.operation
  ) |
  str replace -ra $"\\s*(char gs)\\s*" (char gs) |
  tr (char gs) \0
}

def print-files [state: record, matches: record] {
  if ($matches | is-empty) {
    print $"--Nothing here--(char nul)"
  } else {
    let jj_out = (
      ^jj log -r $matches.commit_id --no-graph
        -T $"self.diff\().files\().map\(|x|
              '(char us)' ++ commit_id.shortest\() ++ '(char us)(char fs)' ++ x.path\() ++ '(char fs)'
            ).join\('(char gs)')"
        --ignore-working-copy
        --at-operation $state.operation
    ) | tr (char gs) \0 | complete
    if ($jj_out.stdout | is-empty) {
      print $"--Nothing here--(char nul)"
    } else {
      print $jj_out.stdout
    }
  }
}

def fzf-pos [] {
  $env.FZF_POS? | default 0 | into int
}

def --wrapped "main update-list" [
  transition: string
  state_file: path
  ...contents: string
] {
  mut state = open $state_file
  let width = $env.FZF_COLUMNS? | default (tput cols) | into int
  let matches = $contents | str join " " | get-matches
  
  match [$state.current_view $transition] {
    [log into] => {
      $state = $state | merge {
        pos_in_log: (fzf-pos)
        current_view: files
      }
      print-files $state $matches
    }
    [files back] => {
      $state = $state | (update current_view log)
      print-log $width $state
    }
    [log _] => {
      print-log $width $state
    }
    [files _] => {
      print-files $state $matches
    }
  }

  $state | save -f $state_file
}

def --wrapped "main preview" [state_file: path, ...contents: string] {
  let state = open $state_file
  if ($state.current_view == log) {
    $state | update pos_in_log (fzf-pos) | save -f $state_file
  }

  let matches = $contents | str join " " | get-matches

  if ($matches | is-empty) {
    print "--Nothing to show--"
  } else {
    if ($state.operation != "@") {
      print $">> (ansi yellow)At operation: ($state.operation)(ansi reset)"
    }
    print (
      ( ^jj log -r $matches.commit_id --no-graph --color always
          -T "description ++
              change_id.shortest(8) ++ ' (' ++ commit_id.shortest(8) ++ '); ' ++
              author ++ '; ' ++ author.timestamp() ++ '\n' ++
              diff.files().len() ++ ' file(s) modified'"
          --ignore-working-copy
          --at-operation $state.operation
      ) | lines | each {$">> ($in)"} | str join "\n"
    )
    let bookmarks = (
      ^jj log -r $"($matches.commit_id):: & \(bookmarks\() | remote_bookmarks\())"
        --no-graph -T 'bookmarks ++ " "' --color always
        --ignore-working-copy
        --at-operation $state.operation
    ) | complete
    let bookmarks = $bookmarks.stdout | str trim
    if not ($bookmarks | is-empty) {
      print $">> In ($bookmarks)"
    }
    print ""
    ( ^jj diff -r $matches.commit_id --color always --git
        ...(if $matches.file? != null {[$matches.file]} else {[]})
        --ignore-working-copy
        --at-operation $state.operation
    ) | deltau wrapper --paging never 
  }
}

def "main on-load-finished" [state_file: path] {
  let state = open $state_file

  let pos = match $state.current_view {
    "log" => $state.pos_in_log
    _ => 0
  }

  let header = match $state.current_view {
    "log" => "Log"
    "files" => "Modified files"
  }

  print ([
    $"pos\(($pos))"
    $"change-header\(($header):)"
  ] | str join "+")
}
