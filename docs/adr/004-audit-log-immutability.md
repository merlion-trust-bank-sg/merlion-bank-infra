# ADR-004: Audit log immutability – S3 Object Lock (governance mode, bypass denied), 365 days

- **Status:** Accepted
- **Date:** 2026-11-05 (revised 2026-11-08 after review)
- **Deciders:** Solutions Architect (on instructor advice), reviewed by DevSecOps (DO1) and SRE
- **Related:** HC-2 Auditability, HC-3 Audit log retention (`docs/requirements.md`); INF-10 (`modules/audit`); `modules/iam-ci/guardrails.tf` (`protect_bootstrap`); APP-11 (deploy audit record); DOC-05 (cost)

## Context
HC-3 requires pipeline and infrastructure audit logs to be retained for at least one year and
protected from tampering **by the engineering team itself**. HC-2 requires every production change
to be traceable (who, what, when, through which pipeline).

S3 Object Lock offers two modes:
- **Compliance:** no one, including the root user, can delete or shorten retention until it
  expires. Irreversible once objects are written; the bucket cannot be removed for a year.
- **Governance:** objects are protected, but principals with `s3:BypassGovernanceRetention` can
  remove them early.

Our instructor advised governance mode to avoid irreversible commitments in the shared training
account.

## Decision
**Trail**
- A CloudTrail trail `g4-merlion-trail` (multi-region, read and write management events, log file
  validation) delivers to the audit bucket `g4-merlion-audit-<account-id>` in `us-east-1`.
- Data events are also recorded for the audit bucket, limited to reads, deletes and retention
  changes (`GetObject`, `DeleteObject`, `DeleteObjectVersion`, `PutObjectRetention`,
  `PutObjectLegalHold`) with advanced event selectors. CloudTrail's own `PutObject` deliveries are
  excluded, so the trail does not log its own writes.
- Bucket policy, Object Lock and versioning changes are management events, so the trail records
  them without extra selectors.

**Bucket**
- **Object Lock enabled**, default retention **GOVERNANCE, 365 days**, versioning on, SSE-KMS with a
  dedicated audit key, public access blocked, TLS-only.
- The bucket policy **denies to every principal** `s3:DeleteObject`, `s3:DeleteObjectVersion`,
  `s3:BypassGovernanceRetention` and `s3:PutBucketObjectLockConfiguration`, so neither the objects
  nor the default retention can be changed without first changing the bucket policy. That change
  is itself recorded by CloudTrail.
- The audit key policy denies `kms:DisableKey` and `kms:ScheduleKeyDeletion`, because a disabled
  key stops CloudTrail delivering logs.
- After 365 days, logs are **kept indefinitely**: Object Lock sets the minimum retention, not the
  maximum, and there is no expiration rule.

**Who can touch it**
- The trail, bucket and audit key are created by the **bootstrap layer**, not by the pipeline.
- Every CI role, and every role the pipeline creates through its permissions boundary, carries
  `protect_bootstrap` (`modules/iam-ci/guardrails.tf`), which explicitly denies changes to the audit
  bucket's configuration, reads and deletes of audit objects, retention changes and governance
  bypass, and `StopLogging`, `DeleteTrail`, `UpdateTrail` and event selector changes on trails.
- The pipeline can only `PutObject` deploy records under `deploys/<env>/`.

**What is stored**
- CloudTrail logs.
- **Deploy records** `{actor, approver, PR, commit SHA, image digest or plan, env, timestamp}` for
  every production `terraform apply` and every application deploy (APP-11). GitHub Actions run
  logs expire, so the bucket, not GitHub, is the lasting record of who changed production.
- **EKS audit logs**: the control plane sends them to CloudWatch Logs, and a Firehose subscription
  delivers them to the `eks-audit/<env>/` prefix.

## Alternatives considered
| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Governance mode + bypass denied** | Tamper-resistant in practice; reversible by an auditable policy change; same cost as compliance | An administrator could first remove the Deny statement (visible in CloudTrail) | **Chosen** (instructor advice) |
| Compliance mode | Strongest guarantee: not even root can delete | Irreversible; locks the bucket for a year in a shared account | Rejected |
| Versioning + MFA delete only | Simple | MFA delete needs root credentials; deletes still possible | Rejected |
| CloudWatch Logs only | Easy querying | Retention can be shortened by anyone with logs permissions | Rejected |
| Reuse the account's existing trail | No extra cost | Not ours: we cannot set its retention, bucket policy or key | Rejected |

**Considered, not used:** a lifecycle transition to S3 Glacier Instant Retrieval. CloudTrail log
files are mostly under 128 KB, Glacier IR's minimum billable object size, so a transition would
raise cost rather than lower it.

## Clean-up at the end of the project
Governance mode keeps removal possible, but only through a deliberate, recorded step:
1. An administrator removes the Deny statements from the bucket policy and the audit key policy
   (both changes recorded by CloudTrail).
2. The administrator deletes the objects and versions with `--bypass-governance-retention`.
3. The bucket, trail and key are then destroyed from the bootstrap layer.

This is also why compliance mode was rejected: it would block step 2 for a year.

## Consequences
**Positive**
- Meets HC-3: logs are retained for at least 365 days and cannot be deleted or overwritten in
  normal operation.
- Meets HC-2: every management API call (reads and writes), including `AssumeRoleWithWebIdentity`
  by the CI roles, is recorded with identity and time, together with reads, deletes and retention
  changes on audit objects. Object-level calls on other buckets are not recorded.
- The pipeline cannot weaken the trail, so a compromised workflow cannot hide its own changes.
- Log file validation (signed digest files) detects altered log files.

**Negative / risks**
- Weaker than compliance mode: someone with permission to edit the bucket policy could remove the
  Deny and then bypass retention. Mitigation: that change is logged by CloudTrail; only the
  bootstrap administrator can change the policy.
- The account is shared, so its administrators are outside our team. Mitigation: the same CloudTrail
  record shows any change they make to the bucket, its policy or its key.
- If the audit key is disabled or scheduled for deletion anyway, CloudTrail cannot deliver logs and
  an audit gap opens. Mitigation: the key policy deny above, and an alarm on CloudTrail delivery
  errors (INF-17).
- **Trail limit:** AWS allows 5 trails per region per account, and the account is shared with other
  groups. Mitigation: check `aws cloudtrail describe-trails` before INF-10; if the limit is reached,
  agree a slot with the instructor before building.
- **Cost:** the account already has a trail (`management-events`), so ours is an additional copy of
  management events, billed at about USD 2 per 100,000 events, plus the selected data events. Small,
  and included in the cost estimate (DOC-05).

## Evidence (to be completed in INF-10)
- `get-object-lock-configuration` → `ObjectLockEnabled: Enabled`, `Mode: GOVERNANCE`, `Days: 365`
- `get-trail-status` → `IsLogging: true`, no `LatestDeliveryError`
- `get-event-selectors` → advanced selectors limited to the audit bucket actions above
- `get-object-retention` on a delivered log → `Mode: GOVERNANCE`, retain-until one year later
- `delete-object` by an engineer → **AccessDenied** (explicit deny in the bucket policy)
- `g4-merlion-ci-staging` attempting `DeleteObject` on an audit object → **AccessDenied**
  (`modules/iam-ci/guardrails.tf`, `DenyAuditTampering`)
- Code: `modules/audit/main.tf`
