variable "project_name" {
  description = "Project name prefix"
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

