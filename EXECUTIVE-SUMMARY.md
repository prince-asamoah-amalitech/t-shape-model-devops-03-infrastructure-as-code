# Executive Summary — Kente Retail Staging Infrastructure

**Prince Asamoah · 2026-09-11 · AWS account 839071825379 (sandbox) · eu-central-1**

---

## What was delivered

The Kente Retail staging environment is now codified in Terraform — twelve managed
resources, applied from a single module with local state, no console clicks, and no
static credentials anywhere in the stack.

A single public subnet (`10.42.1.0/24`) inside a dedicated VPC (`10.42.0.0/16`) holds one
`t3.micro` instance running Amazon Linux 2023. Inbound traffic reaches it only from my own
`/32`, on ports 22 and 8080. The instance reads and writes its S3 bucket through an IAM
role delivered by an instance profile, scoped by ARN to that one bucket; the bucket
itself blocks public access on all four settings and carries no bucket policy.

| Resource | Identifier |
|---|---|
| VPC | `vpc-0d83aa6f4a68f00d5` (10.42.0.0/16) |
| Public subnet | `subnet-096ba70fe6039c2e8` (10.42.1.0/24, eu-central-1a) |
| Internet gateway | `igw-0ac90231eb832afd1` |
| Route table | `rtb-019ee247ea988b613` (0.0.0.0/0 → IGW) |
| Security group | `sg-0db1d61fcdf9bb654` (22, 8080 from one /32; all egress) |
| EC2 instance | `i-0db7465fe5b16f806` (t3.micro, ami-03b2339b9507d3747) |
| S3 bucket | `kente-iac-princeasamoah-data` |
| IAM role / instance profile | `kente-iac-princeasamoah-ec2-role` / `-ec2-profile` |

Every taggable resource carries `Project = kente-iac-princeasamoah`, and the bucket and
IAM role names both use that identifier as their prefix, so teardown is verifiable by tag
sweep as §6 requires.

---

## Cost estimate

AWS list prices for eu-central-1, verified against the AWS pricing pages on 2026-09-11.
Figures assume on-demand Linux with no Savings Plan or free-tier credit.

| Line item | Rate | Monthly if left running | Sizing justification |
|---|---|---|---|
| EC2 `t3.micro` | $0.0120/hr × 730 | **$8.76** | The reference size named in §2. Burstable is the right shape for a staging box that is idle most of the day; 1 GiB RAM comfortably runs the staging service. |
| EBS gp3 root, 8 GiB | $0.0952/GB-month | **$0.76** | 8 GiB is the Amazon Linux 2023 minimum. The instance stores no application data locally — that is what the bucket is for. |
| Public IPv4 address | $0.005/hr × 730 | **$3.65** | Chargeable since February 2024 and unavoidable: §2 requires a publicly reachable instance for the verification step. |
| S3 Standard, ~1 GB | $0.0245/GB-month | **$0.02** | Evidence objects only. Standard rather than Infrequent Access because there is no established access pattern to optimise against, and at this volume the difference is under a cent. |
| VPC, subnet, IGW, route table, security group, IAM role, instance profile | no charge | **$0.00** | Networking and identity primitives are free. Only data transfer out is billed, at $0.09/GB beyond the 100 GB monthly free allowance — this stack moves kilobytes. |
| **Total** | | **≈ $13.19/month** | |

**The figure that actually matters for §8 is not the monthly one.** This stack exists only
for the duration of the lab. About $12.41 of the monthly total is hourly-billed
(≈ $0.017/hr), so a four-hour lifespan costs roughly **$0.07**. The cost control here is
not instance sizing — it is running `terraform destroy` on time, which is why teardown is
treated as a deliverable below rather than an afterthought.

---

## Findings

The starter configuration was incomplete in six places; two would have prevented a
successful apply.

1. **`availability_zone` defaulted to `us-east-1a`** while the region was `eu-central-1` — a zone that does not exist there. Fixed, and a subnet precondition now catches the mismatch at plan time.
2. **No `user_data`** — nothing listened on any port, making the reachability criterion impossible to satisfy honestly. A systemd unit now serves on 8080.
3. **The IAM instance profile carried no tags**, the only taggable resource missing `Project`. Fixed with provider-level `default_tags` so coverage cannot regress.
4. **Port 22 was open with no key pair configured** — the SSH rule led nowhere. A `key_name` variable and a tagged key pair now close the loop.
5. **An unused `aws_caller_identity` data source** was left in the module; it now backs an `aws_account_id` output used in teardown evidence.
6. **No bucket versioning.** Documented rather than built — §9 places it out of scope. It would be my first addition beyond staging.

Beyond the spec I added a `validation` block rejecting any `/0` on `allowed_ssh_cidr`, so
the single most heavily graded rule in §4 is enforced by the code rather than by
discipline.

The full audit, the operational findings from running it, and the gaps I deliberately did
not build are in `ASSUMPTIONS.md`.

---

## Verification

| Criterion | Result |
|---|---|
| App reachable on its port from the permitted CIDR | `HTTP/1.0 200 OK` on `18.153.48.158:8080` |
| Instance reachable by SSH with the key pair | Connected as `ec2-user@ip-10-42-1-115` |
| Instance uses an IAM role, not static credentials | Identity is `assumed-role/kente-iac-princeasamoah-ec2-role/i-…`; no `~/.aws` exists on the box |
| Bucket accepts an object | `evidence.txt` uploaded, listed, and read back from the instance |
| IAM policy is genuinely scoped | Bare `aws s3 ls` denied — `s3:ListAllMyBuckets` is not granted |
| Bucket blocks public access | All four settings `true`; no bucket policy exists |
| Tagging convention holds | All 9 taggable resources carry `Project` |

Full transcripts — init, validate, plan, apply, and each verification above — are in
`evidence/`.

---

## Teardown

All twelve resources have been destroyed and the teardown independently verified.
`terraform state list` is empty.

`terraform destroy` required two passes. The first removed eleven resources and halted
with `BucketNotEmpty`: the object written during the bucket verification was still
present, and the configuration deliberately sets no `force_destroy`, so an accidental
destroy cannot silently delete application data. After emptying the bucket, the second
pass completed.

| Check | Result |
|---|---|
| EC2 instances tagged `Project` | Both `terminated` |
| IAM role and instance profile | `NoSuchEntity` |
| S3 bucket | 404 Not Found |
| VPC tagged `Project` | No results |
| Key pairs | Both deleted, including one created early under a mistyped name |

Two caveats for whoever verifies this independently. Terminated instances remain visible
to `describe-instances` and the Resource Groups Tagging API for roughly an hour, so a
clean teardown shows every instance in state `terminated` rather than an empty result.
And the IAM tag sweep was unavailable — IAM is indexed only through us-east-1, which this
sandbox role is not permitted to query — so IAM teardown was confirmed directly with
`iam get-role` and `iam get-instance-profile`.

The most durable lesson of the teardown is that the only resources at risk of being left
behind were the ones Terraform never managed: a key pair created by CLI, untagged and
under a mistyped name, invisible to every tag-based check. Managing it as an
`aws_key_pair` resource would have destroyed it with everything else.
