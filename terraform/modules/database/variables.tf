variable "project_name" {
  description = "Project name prefix"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for RDS"
  type        = list(string)
}

variable "vpc_id" {
  description = "VPC ID (passed from networking module)"
  type        = string
}

variable "app_sg_id" {
  description = "App security group ID (allowed to connect to RDS)"
  type        = string
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  sensitive   = true
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}
