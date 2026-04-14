# Reflection — aws-autoscale-stack

## What the Project Covers

This capstone deployed a three-tier web application — Nginx reverse proxy, Flask/gunicorn application tier, and RDS MySQL database — on AWS using Terraform for infrastructure provisioning and Ansible for configuration management. The application tier runs inside an Auto Scaling Group, scaling automatically via CloudWatch alarm-based simple scaling policies that add or remove one Flask instance at a time in response to CPU utilisation thresholds.

---

## Challenges

### 1. Ansible over SSM on macOS hung indefinitely

The single hardest problem in the project was that `ansible all -m ping` hung without error on the control machine. Every AWS-side indicator was healthy: all EC2 instances were `Online` in Systems Manager, `aws ssm start-session` connected successfully, `aws ssm send-command` executed correctly, and direct boto3 calls to `start_session()` worked fine.

The hang was controller-side. By instrumenting the `amazon.aws.aws_ssm` collection's source code, the exact stall point was identified inside `_init_clients()`, which uses `select.poll()` to wait on a PTY file descriptor — a call that behaves differently on macOS compared to Linux. No amount of collection version pinning, virtualenv isolation, or environment variable adjustment resolved it.

The fix was to move the Ansible controller into a Linux Docker container. The same inventory, credentials, and playbook that hung on macOS connected and executed correctly on the first attempt inside the container. The `Dockerfile.ansible` and `with-docker-ansible.sh` wrapper now form a permanent part of the project.

**Lesson:** When a tool fails only in your specific environment and works everywhere else, isolate the environment before debugging the tool. A containerised control node is a low-overhead solution that eliminates an entire class of platform-specific compatibility problems.

### 2. SSM requires instance IDs as Ansible hostnames

The dynamic inventory plugin (`amazon.aws.aws_ec2`) defaults to private IP addresses as hostnames. The `amazon.aws.aws_ssm` connection plugin requires EC2 instance IDs — not IPs, not DNS names — to establish a session. Setting `hostnames: [instance-id]` in `aws_ec2.yml` was a one-line fix but a non-obvious one: the failure mode was a silent hang rather than a clear error message.

### 3. Amazon Linux 2 vs Amazon Linux 2023

The original plan used Amazon Linux 2 with `yum`. Switching to AL2023 via SSM Parameter Store AMI lookup required three changes across every Ansible role: replacing `yum:` with `ansible.builtin.dnf:`, replacing the `mysql` client package (not available in AL2023 repos) with `mariadb105`, and updating the AMI data source. These were straightforward sweeps once the pattern was identified.

### 4. gunicorn path on AL2023

On Amazon Linux 2023, `which gunicorn` does not reliably return a consistent path after a pip install into the system Python. The systemd unit file originally used an absolute path that did not exist on some instances. Invoking gunicorn as `python3 -m gunicorn` in the service definition is path-agnostic and resolved the issue permanently.

### 5. Scaled-out instances had no app configuration

This was the most architecturally significant challenge. After the initial Ansible deployment succeeded and the app was running, a load test triggered a scale-out event. The ASG launched new instances — but those instances came up bare. They had no Flask app, no systemd unit, and no database connection. They failed ALB health checks and entered an unhealthy replacement loop.

The root cause was a design gap: Ansible had only configured the instances that existed when `site.yml` was run manually. The ASG had no awareness of Ansible. Infrastructure could scale, but configured application instances could not.

**First attempt — `ansible-pull`:** The launch template `user_data` was initially updated to install Ansible and call `ansible-pull` from GitHub. This failed in sequence: a shebang rendering bug in the Terraform heredoc, then the bootstrap playbook only existing locally and never having been pushed to GitHub, then — after that was resolved — the repo's `ansible.cfg` inheriting `ansible_connection: amazon.aws.aws_ssm` into the local run. A playbook intended to run on `localhost` was attempting to connect to itself via SSM.

**Final solution:** The bootstrap playbook and its Ansible config are written directly to `/etc/aws-autoscale-stack/` by `user_data` at boot — not pulled as playbooks from GitHub. A separate `bootstrap-ansible.cfg` sets only `roles_path`, with no inventory or connection settings. The instance then runs `ansible-playbook -i localhost, -c local bootstrap-app.yml`, which applies the existing `app` role from the cloned repository. The application configuration code comes from Git; the bootstrap scaffolding is self-contained in `user_data`.

**Lesson:** Bootstrap playbooks must have fully isolated Ansible configuration. Any inheritance from a multi-host control-node inventory — inventory paths, connection plugins, remote users — will silently break a localhost run. A second lesson: commit and push before testing any remote-fetch-based bootstrap mechanism.

### 6. IAM policy required four rounds of iteration

The custom least-privilege IAM policy was built up through four rounds of `terraform apply` failure, each revealing a missing permission:

1. `ssm:GetParameter` — needed for the initial SSM Parameter Store AMI lookup
2. `iam:CreateServiceLinkedRole` — needed for ALB, ASG, and RDS service-linked role creation
3. CloudWatch write permissions (`PutMetricAlarm`, `DeleteAlarms`, `DescribeAlarms`, and tag operations) — missed entirely because the original design used target tracking, which creates CloudWatch alarms internally without requiring CloudWatch write permissions from the caller; switching to explicit alarm-based scaling exposed this gap
4. `iam:GetRolePolicy`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy` for inline IAM policy management, and `ssm:ListCommands` / `ssm:ListCommandInvocations` for debugging SSM runs

**Lesson:** `aws iam simulate-principal-policy` exists for this reason. Running it against the intended policy before the first `apply` would have surfaced most of these gaps without requiring failed deployments.

### 7. Terraform AMI drift

The launch template originally used `data "aws_ssm_parameter"` to look up the latest AL2023 AMI at plan time. AWS releases new AMIs regularly; on the day after initial deployment, `terraform plan` detected that the current latest AMI differed from the one used at `apply` time and proposed replacing both the Nginx instance and the ASG launch template — unexpectedly, during what should have been a stable operating phase.

**Fix:** After a validated deployment, specific AMI IDs were pinned in `terraform.tfvars`. The SSM lookup is appropriate for provisioning from scratch; pinned IDs are appropriate for an operating stack where unplanned instance replacement is a risk.

---

## Design Decisions

### SSM over SSH bastion

Using AWS Systems Manager for all instance connectivity eliminates port 22 from every security group and removes EC2 key pairs from the stack entirely. The trade-off — instances must have the SSM agent running and an IAM role with `AmazonSSMManagedInstanceCore` attached — is entirely handled by Terraform. The security gain (no exposed ports, full session audit trail in CloudTrail, no key rotation burden) outweighs the setup cost. In practice, SSM also proved more reliable across VPC boundaries than a bastion host would have been, because it routes through AWS's own control plane rather than through the VPC network.

### Alarm-based simple scaling over target tracking

The original design used target tracking at 25% ASG average CPU — a reasonable default because AWS manages the scale-out and scale-in thresholds automatically. During implementation, target tracking was replaced with two explicit CloudWatch alarms driving `SimpleScaling` policies (+1 or -1 instance, 180s cooldown).

The reason was observability. Target tracking can scale by multiple instances in a single action and its scale-in behaviour is opaque. For a capstone demonstration — and for anyone learning autoscaling for the first time — alarm-based scaling is easier to reason about: each scale event is a named CloudWatch alarm state transition, the capacity change is a discrete step, and the cooldown is explicit. The thresholds (20% to scale out, 10% to scale in) were chosen from observed CloudWatch metrics during actual load tests, not from documentation examples. This was a demonstration-first decision, not a claim that simple scaling is universally better.

For a production workload with unpredictable traffic patterns, target tracking remains the better default. The decision to use simple scaling here was deliberate and context-specific.

### Self-bootstrapping instances over a central push model

Three alternatives were considered for configuring newly launched ASG instances: pre-baked AMIs (golden images with Flask pre-installed), a central push triggered by an ASG lifecycle hook and Lambda function, and the approach ultimately chosen — a `user_data` self-bootstrap script that clones the current app code from GitHub and runs `ansible-playbook` locally.

Pre-baked AMIs require a separate image build pipeline and the image becomes stale when app code changes. A lifecycle hook with Lambda adds significant operational complexity. The self-bootstrap approach keeps deployment simple: every new instance configures itself from the current state of the Git repository, with no external trigger and no bespoke tooling. The acknowledged trade-off is a ~2–3 minute startup delay while bootstrap runs, which the ASG health check grace period (300 seconds) accommodates.

### Least-privilege IAM

Using `AdministratorAccess` for the Terraform deployment user is a common shortcut that creates long-term risk. The custom `aws-autoscale-stack-policy` in `docs/iam-policy.json` grants only the specific actions required by this stack. It took four rounds of iteration to reach its final form, but the result is a policy that can be audited, explained, and scoped to exactly the operations Terraform performs.

### RDS gp3 over gp2

`gp3` provides better baseline IOPS at lower cost than `gp2` for equivalent storage size. There is no reason to use `gp2` for new RDS instances.

### AMI pinning for operational stability

After a validated deployment, the SSM Parameter Store AMI lookup was replaced with pinned AMI IDs in `terraform.tfvars`. This makes `terraform plan` predictable on an operating stack — no unintended instance replacement proposals — while keeping the SSM lookup available for fresh provisioning runs where the latest AMI is always desirable.

---

## How IaC Improved Consistency

The most direct benefit of using Terraform and Ansible together was that every environment state was declared in version-controlled code rather than accumulated through manual console actions.

**Reproducibility:** The entire stack — 30+ AWS resources across four modules — can be provisioned from scratch with `terraform apply`, configured with `ansible-playbook site.yml`, and torn down with `terraform destroy`. This was done multiple times during development. Each rebuild produced an identical, working stack without any manual steps in the AWS Console.

**Auditability:** Every infrastructure decision is visible in the repository. The security group rules, the scaling thresholds, the IAM policy, the Ansible roles — all are readable, diffable, and reviewable. When a bug was found (the wrong health check path on the ALB target group, an incorrect RDS endpoint attribute, a missing IAM permission), the fix was a one-line change to a `.tf` or `.yml` file, committed with a message explaining why.

**Drift prevention:** After all load tests and scaling events completed, `terraform plan` reported "No changes. Your infrastructure matches the configuration." ASG instance launches and terminations are managed by AWS, not Terraform, so they do not appear as drift. Everything Terraform owns remained exactly as declared.

**Separation of concerns:** Terraform handles what resources exist and how they are connected. Ansible handles what is installed and configured on those resources. This boundary is clean and intentional: Terraform outputs the RDS endpoint and ALB DNS name; Ansible reads them as variables. Neither tool reaches into the other's domain.

Without IaC, rebuilding this stack after destroying it for cost management would require manually recreating the VPC, subnets, route tables, security groups, ALB, ASG, RDS, and IAM resources in the correct order with the correct cross-references. One missed security group rule or wrong subnet association would produce a stack that appeared to work but had a subtle misconfiguration. IaC makes that class of inconsistency structurally impossible.

---

## Lessons Learned

### Scaling

Autoscaling is not just a capacity management feature — it is a contract between the application and the infrastructure. The ASG can launch instances on demand, but those instances must be able to configure themselves and pass health checks without manual intervention. Getting that contract right (the self-bootstrap design) was the hardest engineering problem in the project and the one that taught the most.

The 300-second health check grace period is not a workaround — it is a deliberate parameter that must be set based on measured bootstrap time. Setting it too low causes instances to be terminated before they finish configuring. Setting it too high delays failure detection for genuinely broken instances. Observing the actual bootstrap duration in CloudWatch logs and instance system logs is the right way to choose it.

Scale-in is quieter than scale-out but more dangerous to get wrong. ALB connection draining (the `WaitingForELBConnectionDraining` state visible in the scaling evidence) ensures in-flight requests complete before an instance is removed. Skipping that configuration would cause visible errors in client responses during every scale-in event.

### Automation

Idempotency is not a nice-to-have — it is the design requirement that makes automation safe to re-run. Every Ansible task in this project is idempotent: `dnf` module won't reinstall what is already installed, `template` module only writes if content changed, `CREATE TABLE IF NOT EXISTS` and `INSERT IGNORE` make the seed safe to replay. Running `ansible-playbook site.yml` a second time on a live stack produced no failures and no unintended changes.

The Docker wrapper for Ansible is also a form of automation hygiene. By encapsulating the Ansible runtime environment in a container, the project eliminates "works on my machine" problems for anyone who checks out the repository and tries to run the playbook on macOS.

### Cloud Infrastructure

Cloud infrastructure has a lot of implicit dependencies that only surface under real conditions. The IAM policy gaps, the AMI drift, the SSM hostname requirement — none of these were visible in the plan. They only appeared when the system ran. The right response is to treat each failure as a discovery and add it to the documentation (`docs/learnings.md`) so the next person — or the next rebuild — does not repeat the same cycle.

Managed services shift operational burden to AWS in exchange for less flexibility. RDS handles backups, patching, and storage management; the ALB handles health routing and connection draining; the ASG handles instance replacement. The operational surface that remains — IAM, security groups, Terraform state, Ansible roles — is small and fully under version control. That trade is almost always the right one.

---

## What I Would Do Differently

1. **Start with Docker for Ansible from day one.** The macOS SSM hang cost significant debugging time. Standardising on a containerised control node at project start removes an entire class of environment-specific problems before they can occur.

2. **Validate remote repository state before testing any remote-fetch bootstrap mechanism.** One `git push` would have eliminated one of the three sequential failures encountered during the first `ansible-pull` experiment. Even though the final design no longer depends on `ansible-pull`, the lesson remains: if an instance is expected to fetch code remotely, the remote repository must be treated as part of the deployment surface.

3. **Run `aws iam simulate-principal-policy` before the first `terraform apply`.** Four rounds of permission-gap iteration could have been compressed into one. Simulating the full set of required API calls against the intended policy before deployment is the correct approach for a least-privilege setup.

4. **Write `load_test.py` and `collect_evidence.sh` before running the playbook.** Having the evidence scripts ready means scaling data can be captured immediately when the stack first becomes healthy, rather than as a separate phase.

5. **Use a CI pipeline for `terraform plan`.** Running Terraform locally works for a capstone, but in a real project a PR-gated plan run ensures no changes are applied without a second set of eyes on the diff.

6. **Separate the Nginx instance into its own Terraform module.** It currently lives in the `asg` module for convenience, but it is a distinct architectural tier with different lifecycle, security group, and configuration concerns. Keeping it co-located with the ASG resources creates coupling that would become a problem in a larger codebase.

---

## How This Maps to Real-World Infrastructure

| Capstone approach | Production equivalent |
|---|---|
| Terraform modules | Reusable module registry (Terraform Registry or internal) |
| Ansible over SSM | AWS Systems Manager State Manager / Run Command automation |
| User_data self-bootstrap | EC2 Image Builder + pre-baked AMIs, or ECS task definitions |
| Alarm-based simple scaling | Target tracking + predictive scaling (CloudWatch ML-based) |
| RDS MySQL gp3 | Aurora MySQL (multi-AZ, automated failover, serverless option) |
| Single NAT Gateway | NAT Gateway per AZ for high availability |
| ansible-vault for secrets | AWS Secrets Manager or Parameter Store SecureString |
| Manual evidence collection | CloudWatch dashboards, alarms, and Contributor Insights |
| Custom least-privilege IAM policy | IAM Access Analyzer + permission boundaries |

The core pattern — immutable infrastructure declared in Terraform, configuration applied by a push tool, stateless application tier behind a load balancer, managed database — is identical to what engineering teams run in production. The main differences are scale, redundancy depth, and the degree of automation around deployment pipelines. The fundamentals do not change.
