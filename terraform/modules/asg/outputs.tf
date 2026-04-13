output "asg_name" {
  description = "Auto Scaling Group name"
  value       = aws_autoscaling_group.app.name
}

output "app_sg_id" {
  description = "App security group ID"
  value       = aws_security_group.app_sg.id
}

output "nginx_public_ip" {
  description = "Public IP of Nginx instance"
  value       = aws_instance.nginx.public_ip
}

output "nginx_instance_id" {
  description = "Nginx instance ID"
  value       = aws_instance.nginx.id
}
