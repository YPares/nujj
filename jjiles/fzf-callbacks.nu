# Used inside fzf by jjiles.nu

use ../deltau.nu
use parsing.nu

def main [] {}

# Replace the (char gs) inserted at the end of the template
# by a NULL that fzf will use as a multi-line record separator
def replace-template-ending [] {
  str replace -ra $"\\s*(char gs)\\s*" (char gs) |
  tr (char gs) \0
}

def print-oplog [width: int, state: record] {
  if $state.is_watching {
    ( print -n
        $"(ansi default_reverse)♡(ansi reset)  (char us)@(char us)(char us)"
        $"(ansi $state.color_config.operation)Live current operation(ansi reset)\n"
        $"│  (ansi default_italic)This operation will be updated whenever any folder in the [jjiles.watched] config section is modified\n"
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

def print-evolog [width: int, state: record] {
  ( ^jj evolog #...$state.jj_revlog_extra_args
      -r $state.selected_change_id
      --color always
      --template $state.revlog_template
      --config $"width=($width)"
      --config $"desc-len=($width / 2 | into int)"
      --ignore-working-copy
      --at-operation $state.selected_operation_id
  ) | replace-template-ending
}

# Get the id that will condition where to look for files
# (either change or commit id), depending on whether evolog is shown
def get-file-index [state] {
  if $state.is_evolog_shown {$state.selected_commit_id} else {$state.selected_change_id}
}

def print-files [state] {
  let jj_out = (
    ^jj log -r (get-file-index $state) --no-graph
      --template
          $"self.diff\().files\().map\(|x|
              '(char us)' ++ change_id.shortest\(8) ++ '(char us)' ++
              commit_id.shortest\(8) ++ '(char us)' ++
              '● (char fs)(ansi $state.color_config.filepath)' ++ x.path\() ++ '(ansi reset)(char fs) [' ++ x.status\() ++ ']'
            ).join\('(char gs)')"
      --ignore-working-copy
      --at-operation $state.selected_operation_id
  ) | tr (char gs) \0 | complete
  if ($jj_out.stdout | is-empty) {
    false
  } else {
    print $jj_out.stdout
    true
  }
}

def do-update [transition state state_file fzf_pos fzf_selection_contents] {
  mut state = $state
  let width = $env.FZF_COLUMNS? | default (tput cols) | into int
  let matches = $fzf_selection_contents | str join " " | parsing get-matches
  
  # We store the current position of the cursor:
  let cell = match $state.current_view {
    "oplog"  => [pos_in_oplog]
    "revlog" => [pos_in_revlog $state.selected_operation_id] 
    "evolog" => [pos_in_evolog $state.selected_change_id]
    "files"  => [pos_in_files (get-file-index $state)]
  }
  if $cell != null and $fzf_pos != null {
    $state = $state | upsert ($cell | into cell-path) ($fzf_pos + 1)
  }
  
  # We update the state to perform the transition (if any happened):
  let updates = match [$state.current_view $state.is_evolog_shown $transition $matches] {
    # From oplog into revlog:
    [oplog _ into {change_or_op_id: $op_id}] => {
      {
        current_view: revlog
        selected_operation_id: $op_id
      }
    }
    # From revlog back to oplog:
    [revlog _ back _] => {
      {current_view: oplog}
    }
    # From revlog into evolog/files:
    [revlog $evo into {change_or_op_id: $change_id, commit_id: $commit_id}] => {
      {
        current_view: (if $evo {"evolog"} else {"files"})
        selected_change_id: $change_id
        default_commit_id: $commit_id
        selected_commit_id: $commit_id
      }
    }
    # From evolog back into revlog:
    [evolog _ back _] => {
      {current_view: revlog}
    }
    # From evolog into files:
    [evolog _ into {commit_id: $commit_id}] => {
      {
        current_view: files
        selected_commit_id: $commit_id
      }
    }
    # From files back to evolog:
    [files true back _] => {
      {current_view: evolog}
    }
    # From files DIRECTLY back to revlog:
    [files false back _] => {
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
    "evolog" => {
      print-evolog $width $state
    }
    "files" => {
      if (not (print-files $state)) {
        if $state.is_evolog_shown {
          $state = $state | (update current_view evolog)
          $state | save -f $state_file
          print-evolog $width $state
        } else {
          $state = $state | (update current_view revlog)
          $state | save -f $state_file
          print-revlog $width $state
        }
      }
    }
  }
}

def --wrapped "main update-list" [
  transition: string
  state_file: path
  fzf_pos: int = 0
  ...contents: string
] {
  do-update $transition (open $state_file) $state_file $fzf_pos $contents
}

def "main toggle-evolog" [state_file: path, fzf_pos: int, ...contents] {
  mut state = open $state_file
  let cur_view = $state.current_view
  $state = $state |
    update is_evolog_shown {not $in} |
    update current_view {if $cur_view == evolog {"revlog"} else {$cur_view}}
  $state | save -f $state_file
  do-update refresh $state $state_file (if $cur_view != evolog {$fzf_pos}) $contents
}

def call-delta [state file] {(
  deltau wrapper
    -s $state.diff_config.double-column-threshold
    --file-style "omit"
    #--file-decoration-style $"($state.color_config.filepath) ul"
    #--file-style $state.color_config.filepath
    #--hunk-label "#"
    --hunk-header-style
      (if $file != null {"line-number"} else {"file line-number"})
    --hunk-header-file-style $state.color_config.filepath
    --hunk-header-line-number-style ""
    --hunk-header-decoration-style "box"
    --paging never
)}

def preview-op [_width state matches] {
  ( ^jj op show
      $matches.change_or_op_id
      --no-graph
      --stat --patch --git
      --color always
      --ignore-working-copy
  ) | call-delta $state $matches.file?
}

def preview-evo [_width state matches] {
  ( ^jj evolog -n1
      -r $matches.commit_id
      #--template "'[[ Changes in ' ++ change_id.shortest(8) ++ ' at ' ++ commit_id.shortest(8) ++ ' ]]\n'"
      --template ""
      --no-graph
      --stat --patch --git
      --color always
      --ignore-working-copy
      --at-operation $state.selected_operation_id
  ) | call-delta $state $matches.file?
}

def preview-rev-or-file [width state matches] {
  if ($state.diff_config.header) {
    let bookmarks = (
      ^jj log -r $"($matches.commit_id):: & \(bookmarks\() | remote_bookmarks\())"
        --template 'bookmarks ++ " "'
        --no-graph
        --color always
        --ignore-working-copy
        --at-operation $state.selected_operation_id
    ) | complete
    let rev_infos = (
      ^jj log -r $matches.commit_id
        --template
            $"change_id.shortest\(8) ++ '(char fs)' ++ author ++ '(char fs)' ++ author.timestamp\() ++ '(char fs)' ++ commit_id.shortest\(8) ++ 
              '\n' ++ description"
        --no-graph
        --color always
        --ignore-working-copy
        --at-operation $state.selected_operation_id
      ) | lines
    let message = $rev_infos | slice 1.. | str join "\n"
    let message = if ($message | str trim | is-empty) {"(no description)"} else {$message}
    let bookmarks = $bookmarks.stdout | str trim
    let bookmarks = if ($bookmarks | is-empty) {""} else {$"(char fs)($bookmarks)"}
    let rewrapped_header = $"($rev_infos.0 | str replace -a ' ' (char rs))($bookmarks)" |
      str replace -a (char fs) " " |
      ^fmt -w ($width | $in * 1.9 | into int) | # hack: fmt doesn't account for ansi color codes
      str replace -a (char rs) " "
    let rewrapped_message = $message |
      str replace -a "\n" "\n\n" | # fmt will not preserve single newlines
      ^fmt -w ($width - 4) |
      str replace -a "\n\n" "\n" |
      lines
    let title = $rewrapped_message | take until {$in =~ '^\s*$'} |
      each {$"(ansi default_reverse) ($in) (ansi reset)"}
    let message_rest = $rewrapped_message | slice ($title | length)..

    ( print
        $rewrapped_header
        "┌"
        ...($title | append $message_rest | each {$"│ ($in)"})
        "└"
        ""
    )
  }

  ( ^jj log -n1
      -r $matches.commit_id --color always
      #--template "'[[ ' ++ change_id.shortest(8) ++ ' at ' ++ commit_id.shortest(8) ++ ' ]]\n'"
      --template ""
      --no-graph
      (if $state.current_view == "files" {"--stat"} else {"--summary"})
      --patch --git
      --ignore-working-copy
      --at-operation $state.selected_operation_id
      ...(if $matches.file? != null {[$matches.file]} else {[]})
  ) | call-delta $state $matches.file?
}

def --wrapped "main preview" [state_file: path, ...contents: string] {
  let state = open $state_file
  let width = $env.FZF_PREVIEW_COLUMNS? | default "80" | into int
  let matches = $contents | str join " " | parsing get-matches

  match [$state.current_view $matches.change_or_op_id?] {
    [_ null] => {
      print $"(ansi default_italic)\(Nothing to show)(ansi reset)"
    }
    [oplog _] => {
      preview-op $width $state $matches
    }
    [evolog _] => {
      preview-evo $width $state $matches
    }
    _ => {
      preview-rev-or-file $width $state $matches
    }
  }
}

def "main on-load-finished" [state_file: path, fzf_pos?: int] {
  let state = open $state_file

  let fzf_pos = if ($fzf_pos == null) {
    match $state.current_view? {
      "oplog" => $state.pos_in_oplog
      "revlog" => ($state.pos_in_revlog | get -i $state.selected_operation_id | default 0)
      "evolog" => ($state.pos_in_evolog | get -i $state.selected_change_id | default 0)
      "files" => ($state.pos_in_files | get -i (get-file-index $state) | default 0)
      _ => 0
    }
  } else {
    $fzf_pos + 1
  }

  let colors = $state.color_config

  let ev_items = if $state.is_evolog_shown {
    [EvoLog     Commit    ""  $colors.commit $state.selected_commit_id?]
  } else {
    ["(EvoLog)" "(Commit" ")" default_dimmed $state.default_commit_id? ]
  }

  let breadcrumbs = [
    [view   menu        prefix      suffix      color             value                       ];
    [oplog  OpLog       Op          ""          $colors.operation $state.selected_operation_id]
    [revlog RevLog      Rev         ""          $colors.revision  $state.selected_change_id?  ]
    [evolog $ev_items.0 $ev_items.1 $ev_items.2 $ev_items.3       $ev_items.4                 ]
    [files  Files       File        ""          $colors.filepath  null                        ]
  ]

  let before = $breadcrumbs | take until {$in.view == $state.current_view?}
  let num_before = $before | length
  let current = $breadcrumbs | get -i $num_before
  let after = $breadcrumbs | slice ($num_before + 1)..

  let header = [
    ...($before | each {|x|
      $"($x.prefix) (ansi $x.color)($x.value)(ansi reset)($x.suffix)"
    })
    ...(if ($current != null) {
      [$"(ansi $"($current.color)_reverse")($current.menu)(ansi reset)"]
    } else {[]})
    ...($after | each {|x|
      $"(ansi attr_dimmed)(ansi $x.color)($x.menu)(ansi reset)"
    })
  ] | str join " > "

  let width = $env.FZF_COLUMNS | into int | $in - 4  # to account for border

  let help = [
    ...(if ($state.current_view == revlog) {[$"Shown revs: (ansi $colors.revision)($state.revset)"]} else {[]})
    "Ctrl+v: Toggle evolog"
    "Shift+arrows: Navigate"
    "Return: Toggle preview"
  ] | str join $"(ansi default_dimmed) | "

  let padding = $width - ($header | ansi strip | str length) - ($help | ansi strip | str length)

  print ([
    $"change-header\(($header)(printf $"%($padding)s")(ansi default_dimmed)($help)(ansi reset))"
    $"pos\(($fzf_pos))"
  ] | str join "+")
}

