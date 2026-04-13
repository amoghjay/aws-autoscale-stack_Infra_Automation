# aws-autoscale-stack

A production-style multi-tier application deployed on AWS using Terraform (IaC) and Ansible (configuration management), featuring auto-scaling based on CPU utilization.

## Architecture

```
Internet
   │
   ▼
[Nginx EC2]  ←── public subnet (reverse proxy + static frontend)
   │
   ▼
[ALB]        ←── public subnets (routes /api/* to Flask)
   │
   ▼
[ASG: Flask EC2 × 2–6]  ←── private subnets (auto-scales at 25% CPU target)
   │
   ▼
[RDS MySQL]  ←── private subnets (accessible from Flask only)
```

**Stack:**
- Cloud: AWS (us-east-1)
- IaC: Terraform with S3 remote state
- Config management: Ansible with dynamic EC2 inventory
- App: Nginx → Flask (gunicorn) → RDS MySQL
- Scaling: Target tracking at 25% ASG average CPU (min 2, max 6)

## Repository Structure

```
aws-autoscale-stack/
├── terraform/
│   ├── main.tf                   # root module
│   ├── variables.tf
│   ├── outputs.tf                # alb_dns_name, nginx_public_ip, db_endpoint, asg_name
│   ├── backend.tf                # S3 remote state
│   ├── terraform.tfvars.example  # copy to terraform.tfvars — never commit
│   └── modules/
│       ├── networking/           # VPC, subnets, IGW, NAT, route tables
│       ├── alb/                  # ALB, listener, target group
│       ├── asg/                  # Launch template, ASG, scaling policy, Nginx EC2
│       └── database/             # RDS MySQL, subnet group, security group
├── ansible/
│   ├── ansible.cfg
│   ├── site.yml                  # master playbook
│   ├── inventory/
│   │   ├── aws_ec2.yml           # dynamic inventory (amazon.aws.aws_ec2 plugin)
│   │   └── tf_outputs.json       # generated — not committed
│   ├── group_vars/
│   │   └── all.yml               # vars sourced from terraform outputs
│   └── roles/
│       ├── frontend/             # Nginx install + config + static HTML
│       ├── app/                  # Flask + gunicorn + systemd unit
│       └── db_init/              # MySQL seed (CREATE TABLE IF NOT EXISTS)
├── scripts/
│   ├── load_test.py              # load generator
│   ├── collect_evidence.sh       # captures scaling evidence via AWS CLI
│   └── README.md
├── docs/
│   ├── iam-policy.json           # least-privilege IAM policy for deployment user
│   └── architecture.md           # architecture doc (PDF deliverable source)
├── evidence/                     # screenshots + logs (not committed)
├── .gitignore
└── README.md
```

## Prerequisites

| Tool | Version |
|---|---|
| Terraform | >= 1.6 |
| Ansible | >= 2.16 |
| AWS CLI | >= 2.x |
| Python | >= 3.11 |

## Setup

### 1. AWS IAM User

Create an IAM user with the policy in [docs/iam-policy.json](docs/iam-policy.json) (least-privilege — scoped to EC2, ALB, ASG, RDS, and the state S3 bucket only).

### 2. AWS CLI

```bash
aws configure
# Region: us-east-1 | Output: json
aws sts get-caller-identity  # verify
```

### 3. S3 State Bucket

Create `aws-autoscale-stack-tf-state-amogh` in us-east-1 with versioning enabled and public access blocked.

### 4. SSM Session Manager

Instances connect via AWS SSM — no SSH keys or open port 22 required. The IAM instance profile (`AmazonSSMManagedInstanceCore`) is attached automatically by Terraform.

Install the SSM plugin locally if you want direct console access to instances:
https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

### 5. Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your db credentials
terraform init
terraform plan
terraform apply 2>&1 | tee ../evidence/terraform_apply.log
terraform output -json > ../ansible/inventory/tf_outputs.json
```

### 6. Ansible

```bash
cd ansible
docker build --no-cache -f Dockerfile.ansible -t capstone-ansible:ssm .
./with-docker-ansible.sh ansible all -m ping -f 1
./with-docker-ansible.sh ansible-playbook site.yml 2>&1 | tee ../evidence/ansible_run.log
```

### 7. Verify

```bash
ALB=$(cat inventory/tf_outputs.json | python3 -c "import sys,json; print(json.load(sys.stdin)['alb_dns_name']['value'])")
curl http://$ALB/items
```

## Load Testing

```bash
mkdir -p evidence
bash scripts/collect_evidence.sh --duration 600 --interval 30
python3 scripts/load_test.py \
  --url http://<ALB-DNS>/items \
  --workers 200 \
  --duration 300 \
  --progress-interval 15 \
  --output evidence/load_test_results.json
```

Watch in AWS Console: EC2 → Auto Scaling Groups → your ASG → Activity tab.

## Cost

~$3.10/day while running. **Destroy when not working:**

```bash
cd terraform && terraform destroy
```

The S3 state bucket persists free between sessions. Re-apply takes ~10 minutes.

## Design Decisions

- **Private subnets for app + DB** — no direct internet exposure; all traffic routes through ALB or NAT
- **Nginx as reverse proxy** — single public-facing EC2 serving static content and forwarding API traffic to the ALB
- **Gunicorn over Flask dev server** — production-grade, handles concurrent connections
- **Target tracking over step scaling** — AWS manages the math; simpler and more responsive
- **NAT Gateway over NAT instance** — managed, no single-point-of-failure, no patching overhead
- **`skip_final_snapshot = true`** — teardown environment; not appropriate for production
