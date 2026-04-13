output "alb_dns_name" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "alb_target_group_arn" {
  description = "Flask target group ARN"
  value       = aws_lb_target_group.flask.arn
}

output "alb_sg_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb_sg.id
}
