# Used inside fzf by jjiles.nu

use ./deltau.nu

def main [] {}

def get-matches [
]: string -> record<change_id?: string, file?: string> {
  let change_id_parser = $"(char us)\(?<change_id>.+)(char us)"
  let file_parser = $"(char fs)\(?<file>.+)(char fs)"

  let text = $in
  [
    ...($text | parse -r $change_id_parser)
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
      ^jj log -r $matches.change_id --no-graph
        -T $"self.diff\().files\().map\(|x|
              '(char us)' ++ change_id.shortest\(8) ++ '(char us)' ++
              '(char fs)' ++ x.path\() ++ '(char fs)'
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
        change_id: $matches.change_id?
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

  let width = $env.FZF_PREVIEW_COLUMNS? | default "80" | into int

  if ($state.current_view == log) {
    $state | update pos_in_log (fzf-pos) | save -f $state_file
  }
  let matches = $contents | str join " " | get-matches

  if ($matches | is-empty) {
    print "--Nothing to show--"
  } else {
    let bookmarks = (
      ^jj log -r $"($matches.change_id):: & \(bookmarks\() | remote_bookmarks\())"
        -T 'bookmarks ++ " "'
        --no-graph
        --color always
        --ignore-working-copy
        --at-operation $state.operation
    ) | complete
    let rev_infos = (
      ^jj log -r $matches.change_id
        -T $"change_id.shortest\(8) ++ '(char fs)' ++ author ++ '(char fs)' ++ author.timestamp\() ++ '(char fs)' ++ commit_id.shortest\(8) ++ 
            '\n' ++ diff.files\().len\() ++
            '\n' ++ description"
        --no-graph
        --color always
        --ignore-working-copy
        --at-operation $state.operation
      ) | lines
    let msg = $rev_infos | slice (2..)
    let msg = if ($msg | is-empty) {["(no description)"]} else {$msg}
    let bookmarks = $bookmarks.stdout | str trim
    let bookmarks = if ($bookmarks | is-empty) {""} else {$"(char fs)($bookmarks)"}
    let rewrapped_header = $"($rev_infos.0 | str replace -a ' ' (char rs))($bookmarks)" |
      str replace -a (char fs) " " |
      ^fmt -w ($width | $in * 1.9 | into int) | # hack: fmt doesn't account for ansi color codes
      str replace -a (char rs) " "

    print --raw [
      $rewrapped_header
      "│"
      ( $msg |
        update 0 {$"(ansi default_reverse)($in)(ansi reset)"} |
        each {$"│ ($in)"} | str join "\n" | str trim |
        ^fmt -w $width -p "│ "
      )
      "│"
      $"($rev_infos.1) file\(s) modified"
      ""
    ]
    ( ^jj diff -r $matches.change_id --color always
        --git
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
    "log" => [
      $"Op (ansi cyan)($state.operation)(ansi reset)"
      $"(ansi magenta_reverse)Log(ansi reset)"
    ]
    "files" => [
      $"Op (ansi cyan)($state.operation)(ansi reset)"
      $"Rev (ansi magenta)($state.change_id)(ansi reset)"
      $"(ansi green_reverse)Files(ansi reset)"
    ]
  }

  print ([
    $"change-header\(($header | str join ' > '))"
    $"pos\(($pos))"
  ] | str join "+")
}

