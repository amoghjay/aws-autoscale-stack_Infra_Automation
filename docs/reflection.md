# Reflection — aws-autoscale-stack

## What the Project Covers

This capstone deployed a three-tier web application (Nginx → Flask/gunicorn → RDS MySQL) on AWS using Terraform for infrastructure provisioning and Ansible for configuration management. The infrastructure scales automatically based on CPU load via an Auto Scaling Group with a target-tracking policy.

---

## Challenges

### 1. Ansible SSM connectivity on macOS

The single hardest problem in this project was that `ansible all -m ping` hung indefinitely on the control machine. All AWS-side indicators were healthy: instances were online in Systems Manager, `aws ssm start-session` connected successfully, and direct boto3 calls worked. The hang was controller-side, inside Ansible's `amazon.aws.aws_ssm` connection plugin's `_init_clients()` method, which stalls waiting on a PTY file descriptor using `select.poll()` — a call that behaves differently on macOS.

The debugging process involved:
- Confirming SSM was healthy with `aws ssm start-session` and `send-command`
- Testing one host at a time with `-l <instance-id> -f 1`
- Pinning `amazon.aws` collection versions and testing in a clean virtualenv
- Instrumenting the collection's source code to find the exact hang location

The resolution was to run Ansible from a Linux Docker container, where the same inventory and credentials worked correctly on the first attempt. The full root-cause write-up is in `docs/learnings.md`.

**Lesson:** When a tool works everywhere except your specific environment, isolate the environment before debugging the tool. A containerised control node is a practical solution with no AWS-side overhead.

### 2. Dynamic inventory hostname format

SSM requires EC2 instance IDs (not IP addresses or DNS names) as Ansible hostnames. The dynamic inventory plugin defaults to private IPs, which made `ansible_connection: amazon.aws.aws_ssm` fail silently. Setting `hostnames: [instance-id]` in `aws_ec2.yml` resolved it.

### 3. Amazon Linux 2 vs AL2023

The initial plan used Amazon Linux 2 with `yum`. AL2023 ships with `dnf` and does not have the `mysql` client package — only `mariadb`. Updating the AMI lookup to use AL2023 via SSM Parameter Store and replacing `yum:` with `ansible.builtin.dnf:` across all roles was a straightforward but necessary sweep.

### 4. Module path for gunicorn

On AL2023, `which gunicorn` does not reliably return a consistent path after a pip install into the system Python. Invoking it as `python3 -m gunicorn` in the systemd unit is path-agnostic and works regardless of installation location.

---

## Design Decisions

### SSM over SSH bastion

Using AWS Systems Manager for Ansible connectivity eliminates port 22 from every security group and removes the need for EC2 key pairs entirely. The trade-off is that instances must have the SSM agent running and an IAM role with `AmazonSSMManagedInstanceCore` attached — both of which are straightforward to provision with Terraform. The security gain (no exposed ports, audit trail in CloudTrail, no key management) outweighs the setup cost.

### Target tracking scaling policy

Target tracking is simpler than step scaling: AWS manages the scale-out and scale-in thresholds automatically around a single target value. The initial target was 60% CPU, but the lightweight `/items` workload proved more latency-bound than CPU-bound, so the policy was tuned to 25% ASG average CPU to demonstrate scaling behavior clearly for the capstone. There is no need to define separate up/down alarms or calculate step adjustments.

### Least-privilege IAM

Using `AdministratorAccess` for the Terraform deployment user is a common shortcut that creates long-term risk. The custom `aws-autoscale-stack-policy` in `docs/iam-policy.json` grants only the specific actions needed for this stack. It required a few iterations (adding `ssm:GetParameter` for AMI lookup and `iam:CreateServiceLinkedRole` for ELB/ASG/RDS) but the result is a policy that can be audited and understood.

### RDS gp3 over gp2

`gp3` provides better baseline IOPS at lower cost than `gp2` for the same storage size. There is no reason to use `gp2` for new RDS instances.

---

## What I Would Do Differently

1. **Start with Docker for Ansible from day one.** The macOS SSM hang cost significant debugging time. Standardising on a containerised control node removes an entire class of environment-specific problems.

2. **Write `load_test.py` and `collect_evidence.sh` before running the playbook.** Having the scripts ready means scaling evidence can be captured immediately after the stack comes up, rather than as a separate phase.

3. **Use a CI pipeline (GitHub Actions) for `terraform plan`.** Running Terraform locally works for a capstone, but in a real project a PR-gated plan ensures no one applies unreviewed changes.

4. **Separate the Nginx instance into its own Terraform module.** It is currently in the `asg` module for convenience, but logically it is a distinct tier.

---

## How This Maps to Real-World Infrastructure

| Capstone approach | Production equivalent |
|-------------------|----------------------|
| Terraform modules | Reusable module registry (Terraform Registry / internal) |
| Ansible SSM | AWS Systems Manager State Manager / Run Command automation |
| Target tracking ASG | ECS/Fargate with Application Auto Scaling |
| RDS MySQL | Aurora MySQL (multi-AZ, automated failover) |
| Single NAT Gateway | NAT Gateway per AZ (HA) |
| Manual evidence collection | CloudWatch dashboards + alarms |
| ansible-vault | AWS Secrets Manager / Parameter Store SecureString |

The core pattern — immutable infrastructure with Terraform, configuration applied via a push tool, stateless app tier behind a load balancer, managed database — is identical to what teams run in production. The main differences are scale, redundancy, and the degree of automation around deployments.
