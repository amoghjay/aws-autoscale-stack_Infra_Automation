output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = module.alb.alb_dns_name
}

output "nginx_public_ip" {
  description = "Public IP of the Nginx EC2 instance"
  value       = module.asg.nginx_public_ip
}

output "db_endpoint" {
  description = "RDS MySQL endpoint"
  value       = module.database.db_endpoint
}

output "asg_name" {
  description = "Auto Scaling Group name"
  value       = module.asg.asg_name
}

output "alb_target_group_arn" {
  description = "ALB target group ARN (needed for collect_evidence.sh)"
  value       = module.alb.alb_target_group_arn
}
