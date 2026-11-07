# The GitHub Actions OIDC provider already exists in this shared training account, and there can be
# only one per URL. Read it instead of creating it, so this stack never owns (or deletes) a resource
# other groups depend on. modules/iam-ci uses its ARN for the CI role trust policies.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  lifecycle {
    postcondition {
      condition     = contains(self.client_id_list, "sts.amazonaws.com")
      error_message = "The existing GitHub OIDC provider doesn't list sts.amazonaws.com as an audience."
    }
  }
}
