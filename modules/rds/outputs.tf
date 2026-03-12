output "instance_id" {
  description = "Identifier of the DB instance."
  value       = aws_db_instance.this.identifier
}

output "instance_arn" {
  description = "ARN of the DB instance."
  value       = aws_db_instance.this.arn
}

output "instance_resource_id" {
  description = "Immutable resource ID of the instance. This is what an rds-db:connect IAM policy names, not the identifier."
  value       = aws_db_instance.this.resource_id
}

output "endpoint" {
  description = "Host and port to connect to, as host:port."
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "DNS name of the instance without the port."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Port the instance listens on."
  value       = aws_db_instance.this.port
}

output "database_name" {
  description = "Name of the database created on first boot."
  value       = aws_db_instance.this.db_name
}

output "master_username" {
  description = "Master user name. The password lives in Secrets Manager and is not exposed here."
  value       = aws_db_instance.this.username
}

output "master_user_secret_arn" {
  description = "ARN of the Secrets Manager secret RDS manages the master password in. Grant the application secretsmanager:GetSecretValue on this."
  value       = aws_db_instance.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "Security group in front of the instance. Reference it from the application security group rather than widening it here."
  value       = aws_security_group.this.id
}

output "subnet_group_name" {
  description = "Name of the DB subnet group."
  value       = aws_db_subnet_group.this.name
}

output "parameter_group_name" {
  description = "Name of the parameter group attached to the instance."
  value       = aws_db_parameter_group.this.name
}

output "monitoring_role_arn" {
  description = "ARN of the enhanced monitoring role, or null when monitoring_interval is zero."
  value       = var.monitoring_interval > 0 ? aws_iam_role.monitoring[0].arn : null
}

output "psql_command" {
  description = "Command that reads the master password out of Secrets Manager and opens a psql session."
  value = join(" ", [
    "PGPASSWORD=$(aws secretsmanager get-secret-value",
    "--secret-id ${aws_db_instance.this.master_user_secret[0].secret_arn}",
    "--query SecretString --output text | jq -r .password)",
    "psql -h ${aws_db_instance.this.address} -p ${aws_db_instance.this.port}",
    "-U ${aws_db_instance.this.username} -d ${aws_db_instance.this.db_name}",
  ])
}
