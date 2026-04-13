# Architecture — aws-autoscale-stack

## Overview

Multi-tier web application deployed on AWS with auto-scaling, managed entirely through Terraform (infrastructure) and Ansible (configuration).

```
Internet
   │
   ▼
┌──────────────────────────────────────────────────────┐
│  VPC  10.0.0.0/16                                    │
│                                                      │
│  Public Subnets (us-east-1a/b)                       │
│  ┌─────────────┐    ┌──────────────────────────┐    │
│  │  Nginx EC2  │    │  Application Load Balancer│    │
│  │  t3.micro   │    │  (internet-facing, :80)   │    │
│  │  :80        │    └──────────┬───────────────┘    │
│  └──────┬──────┘               │                    │
│         │ /api/ proxy          │ forward :5000       │
│         └──────────────────────┘                    │
│                                                      │
│  Private Subnets (us-east-1a/b)                      │
│  ┌───────────────────────────────────────────────┐   │
│  │  Auto Scaling Group (min 2 / max 6)           │   │
│  │  ┌─────────────┐  ┌─────────────┐            │   │
│  │  │ Flask :5000 │  │ Flask :5000 │  ···       │   │
│  │  │  t3.micro   │  │  t3.micro   │            │   │
│  │  └──────┬──────┘  └──────┬──────┘            │   │
│  └─────────┼────────────────┼───────────────────┘   │
│            └────────┬───────┘                        │
│                     │ MySQL :3306                     │
│  ┌──────────────────▼───────────────────────────┐    │
│  │  RDS MySQL 8.0  db.t3.micro  (Multi-AZ SG)  │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  (Ansible control plane: SSM via AWS Systems Manager)│
└──────────────────────────────────────────────────────┘
```

---

## Component Inventory

| Component | Resource | Details |
|-----------|----------|---------|
| VPC | `aws_vpc` | `10.0.0.0/16`, DNS hostnames enabled |
| Public subnets | `aws_subnet` ×2 | `10.0.1.0/24`, `10.0.2.0/24` — us-east-1a/b |
| Private subnets | `aws_subnet` ×2 | `10.0.3.0/24`, `10.0.4.0/24` — us-east-1a/b |
| Internet Gateway | `aws_internet_gateway` | Public subnet egress |
| NAT Gateway | `aws_nat_gateway` | Private subnet egress (in public-1a) |
| ALB | `aws_lb` | Internet-facing, spans both public subnets |
| ALB Target Group | `aws_lb_target_group` | Port 5000, health check `/health` |
| Launch Template | `aws_launch_template` | AL2023 (SSM Parameter Store AMI), t3.micro |
| Auto Scaling Group | `aws_autoscaling_group` | min 2 / desired 2 / max 6, private subnets |
| Scaling Policy | `aws_autoscaling_policy` | Target tracking, 25% CPU, 300s warmup |
| Nginx EC2 | `aws_instance` | t3.micro, public subnet, reverse proxy |
| RDS MySQL | `aws_db_instance` | MySQL 8.0, db.t3.micro, gp3, encrypted |
| SSM IAM Role | `aws_iam_role` | `AmazonSSMManagedInstanceCore` + S3 transport |
| Terraform state | S3 + DynamoDB | `aws-autoscale-stack-tf-state-amogh`, encrypted |

---

## Traffic Flow

### User request
```
Browser → Nginx (:80) → /api/* proxy → ALB (:80) → Flask (:5000) → RDS MySQL (:3306)
```

### Ansible configuration
```
Laptop (Docker) → AWS SSM → EC2 Instance (SSM Agent)
                    │
                    └── S3 bucket (file transport for Ansible modules)
```

No SSH. No port 22. No bastion host. All management traffic flows through AWS Systems Manager.

---

## Ansible Roles

| Role | Hosts | What it does |
|------|-------|-------------|
| `frontend` | `role_nginx` | Installs Nginx, templates `nginx.conf.j2` (reverse proxy to ALB) and `index.html.j2` |
| `app` | `role_app` | Installs Flask + gunicorn, deploys `app.py`, creates systemd unit `flask.service` |
| `db_init` | `role_app` (run_once) | Installs mariadb client, runs `seed.sql` — idempotent (`CREATE TABLE IF NOT EXISTS` + `INSERT IGNORE`) |

Inventory is dynamic (`amazon.aws.aws_ec2`), filtered by instance tags, using instance IDs as hostnames (required by SSM transport).

---

## Scaling Policy

| Parameter | Value |
|-----------|-------|
| Policy type | Target Tracking |
| Metric | `ASGAverageCPUUtilization` |
| Scale-out target | 25% ASG average CPU |
| Scale-in threshold | AWS-managed by target tracking |
| Instance warmup | 300 seconds |
| Minimum instances | 2 |
| Maximum instances | 6 |
| Health check type | ELB (ALB health checks drive ASG decisions) |
| Health check grace period | 300 seconds |

---

## Security Design

| Concern | Approach |
|---------|----------|
| No public SSH | Port 22 not open on any security group |
| No EC2 key pairs | Removed from Terraform — unnecessary with SSM |
| Least-privilege IAM | Custom `aws-autoscale-stack-policy` (not AdministratorAccess) |
| Instance access | SSM Session Manager only — audited, no open inbound ports |
| Secrets at rest | `ansible-vault` AES256 encrypts `vault.yml` (db password) |
| RDS encryption | `storage_encrypted = true`, gp3 storage |
| State encryption | S3 backend with `encrypt = true` |
| Network isolation | Flask instances in private subnets — not reachable from internet |
| RDS isolation | Security group allows MySQL (:3306) only from `app_sg` |
| ALB isolation | Security group allows :80 only from internet; Flask only from ALB SG |

---

## Terraform Module Structure

```
terraform/
├── main.tf           # Root module — wires all child modules
├── variables.tf      # Input variables
├── outputs.tf        # alb_dns_name, nginx_public_ip, db_endpoint, asg_name
├── backend.tf        # S3 remote state + DynamoDB locking
└── modules/
    ├── networking/   # VPC, subnets, IGW, NAT, route tables
    ├── alb/          # ALB, listener, target group, ALB SG
    ├── asg/          # Launch template, ASG, scaling policy, IAM role, Nginx EC2
    └── database/     # RDS MySQL, DB subnet group, RDS SG
```
