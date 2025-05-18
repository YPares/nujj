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

def print-rev-log [width: int, state: record] {
  ( ^jj ...$state.jj_log_extra_args
      --revisions $state.revset
      --color always
      --template $state.log_template
      --config $"width=($width)"
      --config $"desc-len=($width / 2 | into int)"
      --ignore-working-copy
      --at-operation $state.selected_operation_id
  ) |
  str replace -ra $"\\s*(char gs)\\s*" (char gs) |
  tr (char gs) \0
}

def print-files [state: record, matches: record] {
  if ($matches | is-empty) {
    print $"(ansi default_italic)\(Nothing here)(ansi reset)(char nul)"
  } else {
    let jj_out = (
      ^jj log -r $matches.change_id --no-graph
        -T $"self.diff\().files\().map\(|x|
              '(char us)' ++ change_id.shortest\(8) ++ '(char us)' ++
              '● (char fs)(ansi yellow)' ++ x.path\() ++ '(ansi reset)(char fs) [' ++ x.status\() ++ ']'
            ).join\('(char gs)')"
        --ignore-working-copy
        --at-operation $state.selected_operation_id
    ) | tr (char gs) \0 | complete
    if ($jj_out.stdout | is-empty) {
      print $"(ansi default_italic)\(Nothing here)(ansi reset)(char nul)"
    } else {
      print $jj_out.stdout
    }
  }
}

def --wrapped "main update-list" [
  transition: string
  state_file: path
  fzf_pos: int = 0
  ...contents: string
] {
  mut state = open $state_file
  let width = $env.FZF_COLUMNS? | default (tput cols) | into int
  let matches = $contents | str join " " | get-matches
  
  let cell = match $state.current_view {
    "log" => [pos_in_rev_log $state.selected_operation_id] 
    "files" => [pos_in_file_list $state.selected_change_id]
  }
  if $cell != null {
    $state = $state | upsert ($cell | into cell-path) ($fzf_pos + 1)
  }
  
  match [$state.current_view $transition] {
    [log into] => {
      $state = $state | merge {
        current_view:       files
        selected_change_id: $matches.change_id?
      }
      print-files $state $matches
    }
    [files back] => {
      $state = $state | (update current_view log)
      print-rev-log $width $state
    }
    [log _] => {
      print-rev-log $width $state
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

  let matches = $contents | str join " " | get-matches

  if ($matches | is-empty) {
    print $"(ansi default_italic)\(Nothing to show)(ansi reset)"
  } else {
    let bookmarks = (
      ^jj log -r $"($matches.change_id):: & \(bookmarks\() | remote_bookmarks\())"
        -T 'bookmarks ++ " "'
        --no-graph
        --color always
        --ignore-working-copy
        --at-operation $state.selected_operation_id
    ) | complete
    let rev_infos = (
      ^jj log -r $matches.change_id
        -T $"change_id.shortest\(8) ++ '(char fs)' ++ author ++ '(char fs)' ++ author.timestamp\() ++ '(char fs)' ++ commit_id.shortest\(8) ++ 
            '\n' ++ diff.files\().len\() ++
            '\n' ++ description"
        --no-graph
        --color always
        --ignore-working-copy
        --at-operation $state.selected_operation_id
      ) | lines
    let message = $rev_infos | slice 2.. | str join "\n" | str trim
    let message = if ($message | is-empty) {"(no description)"} else {$message}
    let bookmarks = $bookmarks.stdout | str trim
    let bookmarks = if ($bookmarks | is-empty) {""} else {$"(char fs)($bookmarks)"}
    let rewrapped_header = $"($rev_infos.0 | str replace -a ' ' (char rs))($bookmarks)" |
      str replace -a (char fs) " " |
      ^fmt -w ($width | $in * 1.9 | into int) | # hack: fmt doesn't account for ansi color codes
      str replace -a (char rs) " "
    let rewrapped_message = $message | ^fmt -w ($width - 4) | lines
    let title = $rewrapped_message | take until {$in =~ '^\s*$'} |
      each {$"(ansi default_reverse) ($in) (ansi reset)"}
    let message_rest = $rewrapped_message | slice ($title | length)..

    ( print
        $rewrapped_header
        "┌"
        ...($title | append $message_rest | each {$"│ ($in)"})
        "└"
        $"\(($rev_infos.1) file\(s) modified)"
        ""
    )
    ( ^jj diff -r $matches.change_id --color always
        --git
        ...(if $matches.file? != null {[$matches.file]} else {[]})
        --ignore-working-copy
        --at-operation $state.selected_operation_id
    ) | deltau wrapper --paging never 
  }
}

def "main on-load-finished" [state_file: path] {
  let state = open $state_file

  let pos = match $state.current_view? {
    "log" => ($state.pos_in_rev_log | get -i $state.selected_operation_id | default 0)
    "files" => ($state.pos_in_file_list | get -i $state.selected_change_id | default 0)
    _ => 0
  }

  let breadcrumbs = [
    [view   menu      prefix color   value                        ];
    [op_log "Op log"  Op     blue    $state.selected_operation_id?]
    [log    "Rev log" Rev    magenta $state.selected_change_id?   ]
    [files  Files     File   yellow  null                         ]
  ]

  let before = $breadcrumbs | take until {$in.view == $state.current_view?}
  let num_before = $before | length
  let current = $breadcrumbs | get -i $num_before
  let after = $breadcrumbs | slice ($num_before + 1)..

  let header = [
    ...($before | each {|x|
      $"($x.prefix) (ansi $x.color)($x.value)(ansi reset)"
    })
    ...(if ($current != null) {
      [$"(ansi $"($current.color)_reverse")($current.menu)(ansi reset)"]
    } else {[]})
    ...($after | each {|x|
      $"(ansi attr_dimmed)(ansi $x.color)($x.menu)(ansi reset)"
    })
  ] | str join " > "

  print ([
    $"change-header\(($header))"
    $"pos\(($pos))"
  ] | str join "+")
}

