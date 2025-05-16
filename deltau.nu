# Find the system theme (if on WSL) or leave it to delta to auto-detect
export def theme-flags [] {
  if (which powershell.exe | length) > 0 {
    if (( ^powershell.exe -noprofile -nologo -noninteractive
          '$a = Get-ItemProperty -Path HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize; $a.AppsUseLightTheme'
        ) == "1") {
      ["--light"]
    } else {
      ["--dark"]
    } 
  } else {
    ["--detect-dark-light" "auto"]
  }
}

# Get the layout flags for delta with tput
export def layout-flags [] {
  let width = tput cols | into int
  [ --width $width
    ...(if $width >= 130 {
        ["--side-by-side"]
      } else {[]}
    )
  ]
}
