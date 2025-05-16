export def theme-flags-from-system [] {
  if (which powershell.exe | length) > 0 {
    if (( ^powershell.exe -noprofile -nologo -noninteractive
          '$a = Get-ItemProperty -Path HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize; $a.AppsUseLightTheme'
        ) == "1") {
      "--light"
    } else {
      "--dark"
    } 
  } else {
    "--detect-dark-light auto"
  }
}

export def --wrapped auto-layout [...delta_args] {
  let width = tput cols | into int
  $in | ^delta --width $width ...(
      if $width >= 100 {["--side-by-side"]} else {[]}
  ) ...$delta_args
}

