# Grep for a general pattern
export def grep [
  --dir (-d)=".": path
  --files (-f)="*.hs": string
  --context (-c)=null: list<int>
  pattern: string
] {
  let dir = $dir | path expand
  let line_parser = '^\s+(?<line>[0-9]+)[^\n]+'
  let regex = $"($line_parser)($pattern | str replace ' ' '\s+')"
  glob -D $"\(?i)($dir)/**/($files)" |
  each { |file|
    open $file | nl -ba |
    parse -r $regex |
    update line {into int} |
    insert file ($file | path relative-to $dir) |
    move file --first |
    if ($context != null) {
      insert context {
        (^bat -p --color always $in.file
          -r $"($in.line - $context.0):($in.line + $context.1)"
          -H $in.line
        )
      }
    } else { $in }
  } |
  flatten
}

# Find the scotty routes
export def scotty-routes [
  --dir (-d)=".": path
  --files (-f)="http.hs": string
] {
  grep -d $dir -f $files 'Route\.(?<method>.+) "(?<route>.+)"' |
  update method {str upcase}
}

# Find all imports
export def imports [
  --dir (-d)=".": path
  --files (-f)="*.hs": string
] {
  let pat = 'import (?:qualified )?(?<module>[^\s]+)(?: as (?<alias>[^\s()]+))?(?<rest>.*)'
  grep -d $dir -f $files $pat
}
