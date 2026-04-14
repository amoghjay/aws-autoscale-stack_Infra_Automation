variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS region for runtime bootstrap lookups"
  type        = string
}

variable "app_ami_id" {
  description = "Pinned AMI ID for auto-scaled app instances"
  type        = string
}

variable "nginx_ami_id" {
  description = "Pinned AMI ID for the public Nginx instance"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for ASG instances"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for Nginx instance"
  type        = list(string)
}

variable "alb_target_group_arn" {
  description = "ALB target group ARN"
  type        = string
}

variable "alb_sg_id" {
  description = "ALB security group ID (used to restrict app SG ingress)"
  type        = string
}

variable "ssm_s3_bucket" {
  description = "S3 bucket name used by Ansible SSM connection plugin for file transport"
  type        = string
}

variable "db_username" {
  description = "RDS MySQL master username used by app bootstrap"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "RDS MySQL master password used by app bootstrap"
  type        = string
  sensitive   = true
}

variable "app_bootstrap_repo_url" {
  description = "HTTPS Git URL used by app-instance bootstrap on new app instances"
  type        = string
}

variable "app_bootstrap_repo_ref" {
  description = "Git ref used by app-instance bootstrap on new app instances"
  type        = string
}
