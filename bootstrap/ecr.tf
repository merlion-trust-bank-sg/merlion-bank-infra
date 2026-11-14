# One ECR repository per Bank of Anthos image. In bootstrap because both environments pull the same
# images: an image is built once, tested in staging and the same digest promoted to prod. Only
# g4-merlion-ci-build can push (merlion-bank-app, main); the env roles and every role they create are
# denied pushes and repository changes (modules/iam-ci).
locals {
  images = [
    "frontend",
    "userservice",
    "contacts",
    "ledgerwriter",
    "balancereader",
    "transactionhistory",
    "loadgenerator",
    "accounts-db",
    "ledger-db",
  ]
}

resource "aws_ecr_repository" "app" {
  #checkov:skip=CKV_AWS_136:AES-256 encryption at rest. A KMS key would add key grants for every puller; the images hold public upstream code and no secrets
  for_each = toset(local.images)

  name = "merlion/${each.key}"

  # A tag is pushed once and never changes, so a digest in Git always means the same image
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# Keep recent images for rollback, drop untagged layers left over from failed pushes
resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the 30 most recent images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      },
    ]
  })
}
