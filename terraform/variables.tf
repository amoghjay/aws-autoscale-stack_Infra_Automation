variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name prefix for all resources"
  type        = string
  default     = "aws-autoscale-stack"
}

variable "db_username" {
  description = "RDS MySQL master username"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "RDS MySQL master password"
  type        = string
  sensitive   = true
}
