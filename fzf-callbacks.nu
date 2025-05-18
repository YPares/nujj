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

# Replace the (char gs) inserted at the end of the template
# by a NULL that fzf will use as a multi-line record separator
def replace-template-ending [] {
  str replace -ra $"\\s*(char gs)\\s*" (char gs) |
  tr (char gs) \0
}

def print-oplog [width: int, state: record] {
  if ($state.watched_files | is-not-empty) {
    ( print -n
        $"(ansi default_reverse)♡(ansi reset)  (char us)@(char us)"
        $"(ansi yellow)Live current operation(ansi reset)\n"
        $"│  (ansi default_italic)This operation will be updated whenever any of"
        $" ($state.watched_files | each {$'`($in)`'} | str join ', ') is modified(ansi reset)\n"
        $"│(char nul)"
    )
  }
  ( ^jj op log
      --color always
      --template $state.oplog_template
      --config $"width=($width)"
      --config $"desc-len=($width / 2 | into int)"
      --ignore-working-copy
  ) | replace-template-ending
}

def print-revlog [width: int, state: record] {
  ( ^jj log ...$state.jj_revlog_extra_args
      --revisions $state.revset
      --color always
      --template $state.revlog_template
      --config $"width=($width)"
      --config $"desc-len=($width / 2 | into int)"
      --ignore-working-copy
      --at-operation $state.selected_operation_id
  ) | replace-template-ending
}

def print-files [state: record, change_id: string] {
  let jj_out = (
    ^jj log -r $change_id --no-graph
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

def --wrapped "main update-list" [
  transition: string
  state_file: path
  fzf_pos: int = 0
  ...contents: string
] {
  mut state = open $state_file
  let width = $env.FZF_COLUMNS? | default (tput cols) | into int
  let matches = $contents | str join " " | get-matches
  
  # We store the current position of the cursor:
  let cell = match $state.current_view {
    "oplog" => [pos_in_oplog]
    "revlog" => [pos_in_revlog $state.selected_operation_id] 
    "files" => [pos_in_files $state.selected_change_id]
  }
  if $cell != null {
    $state = $state | upsert ($cell | into cell-path) ($fzf_pos + 1)
  }
  
  # We update the state to perform the transition (if any happened):
  let updates = match [$state.current_view $transition $matches] {
    # From oplog into revlog:
    [oplog into {change_id: $change_id}] => {
      {
        current_view: revlog
        selected_operation_id: $change_id
      }
    }
    # From revlog back to oplog:
    [revlog back _] => {
      {current_view: oplog}
    }
    # From revlog into files:
    [revlog into {change_id: $change_id}] => {
      {
        current_view: files
        selected_change_id: $change_id
      }
    }
    # From files back to revlog:
    [files back _] => {
      {current_view: revlog}
    }
  }

  $state = $state | merge ($updates | default {})
  $state | save -f $state_file

  # We print the new view (or the refreshed current view) for fzf to parse:
  match $state.current_view {
    "oplog" => {
      print-oplog $width $state
    }
    "revlog" => {
      print-revlog $width $state
    }
    "files" => {
      print-files $state $state.selected_change_id
    }
  }
}

def preview-op [_width _state matches] {
  ( ^jj op show
      $matches.change_id
      --no-graph --patch --git
      --color always
      --ignore-working-copy
  ) | deltau wrapper --paging never
}

def preview-rev-or-file [width state matches] {
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

def --wrapped "main preview" [state_file: path, ...contents: string] {
  let state = open $state_file
  let width = $env.FZF_PREVIEW_COLUMNS? | default "80" | into int
  let matches = $contents | str join " " | get-matches

  match [$state.current_view $matches.change_id?] {
    [_ null] => {
      print $"(ansi default_italic)\(Nothing to show)(ansi reset)"
    }
    [oplog _] => {
      preview-op $width $state $matches
    }
    _ => {
      preview-rev-or-file $width $state $matches
    }
  }
}

def "main on-load-finished" [state_file: path] {
  let state = open $state_file

  let pos = match $state.current_view? {
    "oplog" => $state.pos_in_oplog
    "revlog" => ($state.pos_in_revlog | get -i $state.selected_operation_id | default 0)
    "files" => ($state.pos_in_files | get -i $state.selected_change_id | default 0)
    _ => 0
  }

  let breadcrumbs = [
    [view   menu   prefix color   value                        ];
    [oplog  OpLog  Op     blue    $state.selected_operation_id?]
    [revlog RevLog Rev    magenta $state.selected_change_id?   ]
    [files  Files  File   yellow  null                         ]
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

