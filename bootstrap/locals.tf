locals {
  prefix = "${var.team}-merlion" # g4-merlion

  # One state bucket and one KMS key per layer, so each CI role can be limited to its own state.
  # Bootstrap's own state is tagged "shared"; staging and prod are tagged with their env so the
  # environment fence in modules/iam-ci blocks the other env's bucket and key.
  state_layers = merge(
    { bootstrap = { environment = "shared" } },
    { for e in var.environments : e => { environment = e } },
  )
}
