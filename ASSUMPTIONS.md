# Assumptions Log — Kente Retail Staging Stack

**Author:** Prince Asamoah
**Project identifier:** `kente-iac-princeasamoah`
**AWS account:** 839071825379 (sandbox)
**Region / AZ:** eu-central-1 / eu-central-1a
**Date:** 2026-09-11

---

## 1. Values the spec left to me

| Value | What I chose | Why |
|---|---|---|
| VPC CIDR | `10.42.0.0/16` | Starter default, kept. RFC1918 space with no overlap against anything else in the sandbox. A /16 is far larger than one instance needs, but VPC address space is free and it leaves room for private subnets if this stack is ever extended. |
| Subnet CIDR | `10.42.1.0/24` | Genuinely contained within the VPC range as spec §1 requires. 251 usable addresses — oversized for one host, but a /28 would make future additions awkward for no saving. |
| Region | `eu-central-1` (Frankfurt) | Nearest sandbox region; keeps latency reasonable for the reachability check. |
| Availability zone | `eu-central-1a` | Single AZ, which §1 explicitly permits for staging. Chose `a` arbitrarily — no capacity or pricing reason to prefer another. |
| Instance type | `t3.micro` | The reference size named in §2. 2 vCPU burstable / 1 GiB RAM comfortably runs the placeholder HTTP service, and burstable is the right shape for a staging box that is idle most of the day. No reason to deviate, so no deviation to justify. |
| AMI | `ami-03b2339b9507d3747` (Amazon Linux 2023) | Resolved from the public SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` for eu-central-1 rather than copied from another account or region. |
| App port | `8080` | Unprivileged, so the app runs without root. Scoped to my own /32, identically to SSH. |
| Root volume | 8 GiB gp3 (provider default) | The Amazon Linux 2023 minimum. The app stores nothing locally — application data belongs in the S3 bucket. |
| `allowed_ssh_cidr` | My own public IP as a `/32` | Spec §4. Deliberately not a range, not the class network, and never `0.0.0.0/0`. |
| Bucket name | `kente-iac-princeasamoah-data` | `project_tag` + the `bucket_name_suffix` default, satisfying the §6 prefix requirement. |
| State | Local `terraform.tfstate` only | §7. No backend block added, and `.gitignore` keeps state and tfvars out of the repository. |

---

## 2. Gaps I found in the starter

The README warned that every copy of the starter is degraded somewhere. I audited the
whole configuration against the spec rather than looking for a single planted fault, and
found six issues. Two of them would have stopped `apply` outright.

| # | Gap | Spec | Severity | What I did |
|---|---|---|---|---|
| 1 | `availability_zone` defaulted to `us-east-1a` while `aws_region` was set to `eu-central-1`. That AZ does not exist in that region, so `apply` fails at subnet creation. | §1 | Blocker | Set `availability_zone = "eu-central-1a"` in `terraform.tfvars`, and added a `lifecycle.precondition` on `aws_subnet.public` asserting `startswith(var.availability_zone, var.aws_region)` so the mismatch now fails at plan time with a readable message instead of failing mid-apply. |
| 2 | No `user_data` anywhere. Nothing listened on any port, so the Acceptance Criteria requirement to reach the instance on its app port could not be satisfied honestly. | §2 | Blocker | Added `user_data` installing a systemd unit (`staging-app.service`) that serves a static page on 8080 via `python3 -m http.server`. Python 3 ships with AL2023, so nothing is installed at boot. |
| 3 | `aws_iam_instance_profile.app` carried no tags at all — the only taggable resource in the module missing `Project`. The teardown check greps on exactly that tag. | §6 | High | Added `default_tags { Project = var.project_tag }` to the provider rather than patching the one resource, so tag coverage cannot silently regress when resources are added later. |
| 4 | The security group opened port 22, but `aws_instance.app` declared no `key_name` and the role carried no SSM permissions. Nothing could ever log in — the SSH rule led nowhere. | §4 | High | Added a `key_name` variable and wired it into the instance; created a tagged EC2 key pair. |
| 5 | `data "aws_caller_identity" "current"` was declared and never referenced — leftover scaffolding. | — | Low | Used it for a new `aws_account_id` output, which doubles as teardown evidence naming the account the stack was built in. |
| 6 | The bucket has its public access block but no versioning configured. | §3/§9 | Note | Documented, not built — see section 4. |

### What already complied, and which I deliberately did not change

SSH already restricted to a specific CIDR (§4); subnet CIDR genuinely inside the VPC
CIDR (§1); all four public-access-block settings `true` (§3); the IAM policy already
scoped to the two specific bucket ARNs with no wildcard resource (§5); bucket and IAM
role names already prefixed with `project_tag` (§6); local state with no backend
block (§7).

---

## 3. Operational findings from actually running it

These were not visible by reading the configuration. They cost me time during the lab
and are the part I would most want a reviewer to see.

**3.1 A `.tfvars` entry with no matching `variable` block is a warning, not an error.**
I set `key_name` in `terraform.tfvars` before declaring the variable. Terraform emitted
a warning about a value for an undeclared variable, then completed `validate` and
`apply` successfully. The failure surfaced much later as
`Permission denied (publickey)` over SSH, with the instance built and running. State
confirmed the cause: `key_name = ""`. **Lesson:** a clean `validate` does not mean your
variables are wired up; check the plan for the attribute you expect to change.

**3.2 Changing `key_name` forces instance replacement.**
Adding the key to a running instance destroyed and recreated it, producing a new
instance ID and a new public IP. Evidence captured against the first instance was
invalidated, and I had to recapture the port-8080 check so the instance ID in my
evidence matches the one in final state. **Lesson:** get immutable attributes right
before the first apply, not after.

**3.3 The key pair was created outside Terraform, so Terraform could not protect it.**
Because the pair was created with the AWS CLI, it was not in state and was not covered
by `default_tags`. When my sandbox credentials were refreshed, the key pair was no
longer present, but `terraform plan` still proposed an instance referencing it —
the error only appeared at `apply` time as `InvalidKeyPair.NotFound`, after the old
instance had already been destroyed. **Lesson:** infrastructure a module depends on but
does not manage is invisible drift. The fix is an `aws_key_pair` resource reading a
`.pub` file, so the pair is created, tagged, and destroyed with everything else.

**3.4 A correctly least-privileged role cannot discover its own bucket name.**
My first verification script tried to find the bucket with `aws s3api list-buckets`,
which failed with `AccessDenied` — `s3:ListAllMyBuckets` is deliberately not in the
policy. All three granted actions (`GetObject`, `PutObject`, `ListBucket`) operate on a
bucket you must already know the name of. I injected the name from
`terraform output -raw s3_bucket_name` instead. **Lesson:** the correct fix is to pass
the bucket name in via `user_data`, an SSM Parameter, or instance tags — never to widen
the policy so that discovery works.

**3.5 Tag-based teardown checks report resources that no longer exist.**
After the instance replacement, both `resourcegroupstaggingapi get-resources` and
`describe-instances` still listed the terminated instance and its deleted root volume.
Terminated instances remain queryable for roughly an hour. **Lesson:** the reliable
teardown signal is instance *state* (`terminated`), not absence from a tag sweep. This
matters because the instructor's check greps on the tag.

**3.6 IAM resources do not appear in a regional tag sweep.**
`get-resources --region eu-central-1` returned nine ARNs but no IAM role or instance
profile. IAM is global and is only indexed through the `us-east-1` endpoint. I ran a
second sweep there and confirmed the tags directly with `iam list-role-tags` and
`iam get-instance-profile`. Their absence from the regional sweep was an API artifact,
not a tagging failure.

**3.7 Three resources cannot carry tags at all.**
`aws_route_table_association`, `aws_iam_role_policy`, and
`aws_s3_bucket_public_access_block` do not support tagging in AWS. So 9 of the 12
managed resources are taggable and all 9 carry `Project`; the remaining 3 are
sub-resources of parents that are themselves tagged.

---

## 4. Gaps I noted but deliberately did not build

Spec §9 places these out of scope. Each is recorded with the risk it leaves open.

| Gap | Risk if left as-is | Why deferred |
|---|---|---|
| No S3 versioning | An overwrite or delete of application data is unrecoverable | Not required by §3. This would be my first addition for anything beyond staging — it is cheap and the bucket is small. |
| No `force_destroy` on the bucket | `terraform destroy` fails while objects remain, requiring a manual `aws s3 rm` | Arguably correct as-is: an accidental `destroy` should not silently delete data. Noted as a deliberate trade-off, not an oversight. |
| Single AZ, no load balancer, no autoscaling | A zone failure takes the entire stack down; no horizontal scale | §1 permits single-AZ for staging and §9 scopes HA out explicitly. |
| Instance directly internet-facing; no private subnet or NAT gateway | Larger attack surface than a production design should have | §2 requires a public IP for the reachability check. Acceptable for staging; production would put the instance in a private subnet behind a load balancer. |
| No SSM Session Manager access | SSH with a key pair is the only way in, and the key is a long-lived secret on my laptop | Attaching `AmazonSSMManagedInstanceCore` would let me drop the port-22 rule entirely — a better design, but it goes beyond what §4 asks for. |
| Local state, no locking or remote backend | Two concurrent applies would corrupt state; state is not backed up | §7 mandates local state; remote backends are Module 4. |
| No monitoring, alarms, or log shipping | Instance or app failure is invisible until someone checks manually | Not assessed in this lab. |
| Root volume not explicitly encrypted | Data at rest on the EBS volume is unencrypted unless the account default is on | The instance stores no application data by design; it all goes to S3. Would set `encrypted = true` in production regardless. |

---

## 5. Things I added beyond the spec

- **`validation` block on `allowed_ssh_cidr`** rejecting any `/0` prefix, so §4's most
  heavily graded rule is enforced by the code rather than by my memory. A future editor
  cannot widen it to `0.0.0.0/0` without the plan failing.
- **`lifecycle.precondition` on the subnet** tying the AZ to the region (finding #1).
- **Provider-level `default_tags`** so §6 coverage cannot regress (finding #3).
- **`aws_account_id` output** so teardown evidence names the account explicitly.

---

## 6. Security incident during the lab (disclosed)

While recovering the key pair I ran `aws ec2 import-key-pair` with
`--public-key-material fileb://kente-iac-princeasamoah-key.pem` — passing the **private**
key where the public key belongs. The call was rejected with `InvalidKeyPair.Duplicate`,
but the file contents had already been serialized into the request and sent to AWS, and
`ImportKeyPair` request parameters are recorded in CloudTrail. I treated the key as
disclosed.

**Impact assessment:** none material. The key pair was created solely for this lab, was
used only for this sandbox instance, protects no other system, and was deleted at
teardown. The key was subsequently destroyed and replaced.

**What I would do differently:** `--public-key-material` takes the `.pub` file only. In a
production context the response would be immediate rotation of the key pair across every
instance trusting it, plus a CloudTrail review for any use of the compromised key.

I am recording this rather than omitting it because recognising and correctly scoping an
exposure is the point of the exercise.

---

## 7. Verification results

| Check | Spec | Result | Evidence |
|---|---|---|---|
| App reachable on port 8080 from my /32 | §2, AC | `HTTP/1.0 200 OK`, expected HTML returned | `evidence/06-http-8080.txt` |
| SSH reachable with the key pair | §4 | Connected as `ec2-user@ip-10-42-1-115` | `evidence/06a-ssh.txt` |
| Instance identity is an assumed role | §5 | `assumed-role/kente-iac-princeasamoah-ec2-role/i-0db7465fe5b16f806` | `evidence/06b-iam-role-proof.txt` |
| No static credentials on the instance | §5 | `/home/ec2-user/.aws` does not exist | `evidence/06b-iam-role-proof.txt` |
| Bucket accepts an object | §3 | Uploaded, listed, and read back `evidence.txt` | `evidence/06b-iam-role-proof.txt` |
| Policy scope is real | §5 | Bare `aws s3 ls` denied — `s3:ListAllMyBuckets` not granted | `evidence/06b-iam-role-proof.txt` |
| Bucket is not public | §3 | All four blocks `true`; `NoSuchBucketPolicy` (no policy exists) | `evidence/07-pab.txt` |
| Tag coverage | §6 | 9 taggable resources, all carrying `Project` | `evidence/08-tags.txt` |

The denied `aws s3 ls` is the most informative single line in the evidence: it
demonstrates least privilege working as intended, which a passing test cannot.
