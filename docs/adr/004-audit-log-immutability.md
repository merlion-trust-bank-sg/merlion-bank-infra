# ADR-004: Audit log immutability – S3 Object Lock (governance mode, bypass denied), 365 days

- **Status:** Accepted
- **Date:** 2026-11-05
- **Deciders:** Solutions Architect (on instructor advice), reviewed by DevSecOps (DO1)
- **Related:** HC-2 Auditability, HC-3 Audit log retention (`docs/requirements.md`); INF-10 (`modules/audit`); APP-11 (deploy audit record)

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
- A CloudTrail trail (multi-region, management events, log file validation) delivers to one audit
  bucket in `us-east-1`. Data events are also recorded for the audit bucket itself, so any attempt
  to read or delete audit objects is logged.
- The bucket has **Object Lock enabled**, default retention **GOVERNANCE, 365 days**, versioning on,
  SSE-KMS with a dedicated audit key, public access blocked, TLS-only.
- The bucket policy **denies `s3:DeleteObject`, `s3:DeleteObjectVersion` and
  `s3:BypassGovernanceRetention` to every principal**, so governance retention cannot be bypassed
  without first changing the bucket policy.
- Changing the bucket policy is itself recorded by CloudTrail, so any weakening is visible.
- The same bucket holds pipeline deploy records (APP-11) and EKS audit logs, under separate prefixes.
- Resource names use our group prefix `g4-` (assumption A-3).

## Alternatives considered
| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **Governance mode + bypass denied** | Tamper-resistant in practice; reversible by an auditable policy change; same cost as compliance | An administrator could first remove the Deny statement (visible in CloudTrail) | **Chosen** (instructor advice) |
| Compliance mode | Strongest guarantee: not even root can delete | Irreversible; locks the bucket for a year in a shared account | Rejected |
| Versioning + MFA delete only | Simple | MFA delete needs root credentials; deletes still possible | Rejected |
| CloudWatch Logs only | Easy querying | Retention can be shortened by anyone with logs permissions | Rejected |

**Considered, not implemented:** a lifecycle rule moving logs to S3 Glacier Instant Retrieval after
30 days would lower storage cost and keep logs instantly readable. Log volume in this project is
small, so we keep all logs in S3 Standard; a real bank with a year of logs would add it.

## Consequences
**Positive**
- Meets HC-3: logs are retained for 365 days and cannot be deleted or overwritten in normal operation.
- Meets HC-2: every API call, including `AssumeRoleWithWebIdentity` by the CI roles, is recorded with identity and time.
- Log file validation (signed digest files) detects altered log files.
- Storage cost is low (small, compressed JSON files).

**Negative / risks**
- Weaker than compliance mode: someone with permission to edit the bucket policy could remove the
  Deny and then bypass retention. Mitigation: that change is logged by CloudTrail; restrict
  `s3:PutBucketPolicy` on this bucket to the bootstrap administrator.
- The account is shared, so its administrators are outside our team. Mitigation: the same CloudTrail
  record shows any change they make to the bucket, its policy or its key.
- If the audit KMS key is disabled or scheduled for deletion, CloudTrail cannot deliver logs and an
  audit gap opens. Mitigation: an alarm on CloudTrail delivery errors (INF-17), and a key policy that
  limits who can disable the key.

## Evidence (to be completed in INF-10)
- `get-object-lock-configuration` → `ObjectLockEnabled: Enabled`, `Mode: GOVERNANCE`, `Days: 365`
- `get-trail-status` → `IsLogging: true`, no `LatestDeliveryError`
- `get-object-retention` on a delivered log → `Mode: GOVERNANCE`, retain-until one year later
- `delete-object` by an engineer → **AccessDenied** (explicit deny in the bucket policy)
- Code: `modules/audit/main.tf`
