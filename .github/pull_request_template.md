## What changed

## Why

## Jira
SCRUM-<n>: https://<your-site>.atlassian.net/browse/SCRUM-<n>

## Evidence
- [ ] `tf-plan` checks green: gitleaks, fmt, validate, tflint, checkov
- [ ] `plan staging` job log reviewed; prod is planned on `main` after merge

## Constraint impact
- Region (everything stays in `var.region` = us-east-1):
- Audit / retention:
- Credentials (roles, trust, secrets):

## Definition of done
- [ ] Branch is `SCRUM-<n>-*`, commit messages `SCRUM-<n>: type(scope): summary`
- [ ] Reviewer is not the author
- [ ] No secrets, no state files, nothing applied by hand
- [ ] Docs / ADR / diagram updated if the design changed
