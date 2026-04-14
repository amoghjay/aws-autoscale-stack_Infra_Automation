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

variable "app_ami_id" {
  description = "Pinned AMI ID for auto-scaled app instances"
  type        = string
  default     = "ami-098e39bafa7e7303d"
}

variable "nginx_ami_id" {
  description = "Pinned AMI ID for the public Nginx instance"
  type        = string
  default     = "ami-0ea87431b78a82070"
}

variable "app_bootstrap_repo_url" {
  description = "HTTPS Git URL used by app-instance bootstrap on new app instances"
  type        = string
  default     = "https://github.com/amoghjay/aws-autoscale-stack_Infra_Automation.git"
}

variable "app_bootstrap_repo_ref" {
  description = "Git ref used by app-instance bootstrap on new app instances"
  type        = string
  default     = "main"
}
