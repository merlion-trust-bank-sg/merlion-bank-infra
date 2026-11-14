# Service Selection – Merlion Trust Bank

For each major component: what we chose, what we compared it with, and why.
Requirement IDs refer to `docs/requirements.md`; decisions with wider impact have their own ADR.

## Summary
| Area | Chosen | Main alternative(s) | Decision record |
|---|---|---|---|
| Container runtime | Amazon EKS, managed node group | ECS on Fargate, ECS on EC2 | ADR-001 |
| Databases | Amazon RDS for PostgreSQL | Aurora PostgreSQL, PostgreSQL on EKS | This document |
| Container registry | Amazon ECR | GitHub Container Registry, Docker Hub | This document, ADR-007 |
| CI/CD | GitHub Actions | AWS CodePipeline + CodeBuild, Jenkins | This document |
| Pipeline credentials | GitHub OIDC → IAM role per environment | IAM user access keys in GitHub secrets | ADR-005 |
| Infrastructure as code | Terraform | CloudFormation, AWS CDK | This document |
| Secrets | AWS Secrets Manager + External Secrets Operator | SSM Parameter Store, Kubernetes Secrets in Git | This document |
| Encryption keys | AWS KMS customer managed keys | AWS managed keys | This document |
| Ingress | Application Load Balancer via AWS Load Balancer Controller, ACM certificate | NGINX Ingress behind an NLB | This document |
| Observability | Self-hosted Prometheus, Loki, Grafana, Alertmanager on EKS | Amazon CloudWatch, Grafana Cloud | ADR-003 |
| Audit trail | CloudTrail → S3 with Object Lock (governance, 365 days) | CloudWatch Logs only, Object Lock compliance mode | ADR-004 |
| Security scanning | Trivy (dependencies, images), checkov, gitleaks | Snyk, Amazon Inspector | This document |

## Details

### Databases – Amazon RDS for PostgreSQL
- **Why:** Bank of Anthos uses PostgreSQL for `accounts-db` and `ledger-db` (FR-3). RDS gives Multi-AZ failover (NFR-3), automated backups that stay in-region (NFR-4, HC-1), KMS encryption and enforced TLS (`rds.force_ssl`) (NFR-6), and a managed master password in Secrets Manager.
- **Aurora PostgreSQL:** faster failover and storage auto-scaling, but a higher minimum cost than two small RDS instances, which matters for the cost target (NFR-7).
- **PostgreSQL on EKS** (as upstream Bank of Anthos ships it): no managed backups or failover, and data on cluster volumes. Rejected for a regulated ledger.

### Container registry – Amazon ECR
- **Why:** images stay in our AWS account and region; nodes pull with IAM (no registry passwords); immutable tags and scan on push support build-once promotion (ADR-007).
- **GitHub Container Registry / Docker Hub:** images and their metadata would sit outside our AWS region, and pulls would need stored credentials.

### CI/CD – GitHub Actions
- **Why:** our code, PRs and reviews are already in GitHub, so checks and deploys sit next to the review that approves them (HC-2). GitHub environments give the manual production approval, and OIDC removes stored AWS keys (ADR-005).
- **CodePipeline + CodeBuild:** runs inside AWS, but splits the audit trail between GitHub and AWS and is less familiar to the team.
- **Jenkins:** a server we would have to host, patch and secure ourselves.
- **Risk:** CI logs are stored by GitHub outside our region, so CI output must contain no customer data or application logs (ADR-006).

### Infrastructure as code – Terraform
- **Why:** required by the brief (no click-ops); team experience; one tool for AWS resources and Helm releases; `plan` on every PR makes infrastructure changes reviewable (HC-2). State is kept in S3, versioned and encrypted, with S3 lock files.
- **CloudFormation / CDK:** AWS-native, but less familiar to the team, and Helm releases would need a second tool.

### Secrets – AWS Secrets Manager + External Secrets Operator
- **Why:** KMS-encrypted, access controlled and logged by IAM and CloudTrail, integrates with RDS-managed master secrets, supports rotation. External Secrets copies values into Kubernetes Secrets at runtime, so nothing sensitive is in Git, Helm values or images.
- **SSM Parameter Store:** cheaper, but no built-in rotation or RDS integration.
- **Kubernetes Secrets in Git** (even encrypted): secrets would live in the repository history.

### Encryption keys – AWS KMS customer managed keys
- **Why:** separate keys for RDS, S3 (state and audit), CloudWatch Logs and Secrets Manager, with our own key policies, yearly rotation and key use visible in CloudTrail.
- **AWS managed keys:** no control over the key policy and no separation between data sets.

### Ingress – ALB via AWS Load Balancer Controller
- **Why:** HTTPS with a free ACM certificate, managed by AWS across 2 AZs, configured from Kubernetes `Ingress` objects, and ALB metrics (5xx, `TargetResponseTime`) feed our SLOs (NFR-1, NFR-2).
- **NGINX Ingress behind an NLB:** more control, but one more component to run and patch, and TLS certificates to manage in the cluster.

### Security scanning – Trivy, checkov, gitleaks
- **Why:** open-source, run inside GitHub Actions, and fail the build on CRITICAL findings that have a fix (HIGH findings are reported in CI and in ECR's scan on push, not blocking, because the application is unmodified upstream code). Trivy covers dependencies and images, checkov covers Terraform, gitleaks covers committed secrets. No code or results are sent to a third-party SaaS.
- **Snyk:** strong vulnerability data, but a SaaS service that receives our dependency data.
- **Amazon Inspector:** useful for images already in ECR, but it scans after the push, while we want the gate to block the push.

## Out of this document
Runtime, observability, audit, pipeline credentials and region each have their own ADR, listed in the summary. This document only summarises them.
