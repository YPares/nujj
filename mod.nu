export use nujj.nu
export use nugh.nu
export use ./jjiles

export-env {
  load-env {
    nujj-config: {
      completion: {
        description: "description.first_line() ++ ' (modified ' ++ committer.timestamp().ago() ++ ')'"
      }
      tblog: {
        default: {
          change_id: "change_id.shortest(8)"
          description: description
          author: "author.name()"
          creation_date: "author.timestamp()"
          modification_date: "committer.timestamp()"
        }
      }
      caps: {
        revset: "mutable() & reachable(@, trunk()..)"
      }
    }
  }
}
