# delta utils

# Find the system theme (if on Windows/WSL) or leave it to delta to auto-detect
export def theme-flags [] {
  if (which reg.exe | length) > 0 {
    let val = ^reg.exe QUERY 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' /v SystemUsesLightTheme |
      lines | slice (-2..-2) | split row " " | last
    if $val == "0x1" {
      ["--light"]
    } else {
      ["--dark"]
    }
  } else {
    ["--detect-dark-light" "auto"]
  }
}

# Get the layout flags for delta
export def layout-flags [] {
  let width = $env.FZF_PREVIEW_COLUMNS? |
    default $env.FZF_COLUMNS? |
    default (tput cols) |
    into int
  [ --width $width
    ...(if $width >= 130 {
        ["--side-by-side"]
      } else {[]}
    )
  ]
}

# Run delta with theme and layout detection
export def --wrapped wrapper [...args] {
  ^delta ...(theme-flags) ...(layout-flags) ...$args
}
