output "db_endpoint" {
  description = "RDS MySQL hostname (no port)"
  value       = aws_db_instance.mysql.address
}

output "db_name" {
  description = "Database name"
  value       = aws_db_instance.mysql.db_name
}
