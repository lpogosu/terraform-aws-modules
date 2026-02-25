output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "app_security_group_id" {
  description = "Security group the application tier attaches to. It is the only source the database accepts."
  value       = aws_security_group.app.id
}

output "database_endpoint" {
  description = "Host and port of the PostgreSQL instance."
  value       = module.database.endpoint
}

output "database_secret_arn" {
  description = "Secrets Manager secret holding the master password. Grant the application secretsmanager:GetSecretValue on it."
  value       = module.database.master_user_secret_arn
}

output "database_psql_command" {
  description = "Read the password out of Secrets Manager and open psql."
  value       = module.database.psql_command
}

output "site_domain_name" {
  description = "CloudFront domain name serving the frontend."
  value       = module.frontend.distribution_domain_name
}

output "site_bucket" {
  description = "Origin bucket the build output is synced to."
  value       = module.frontend.bucket_id
}

output "site_deploy_commands" {
  description = "Sync the bundle and invalidate the edge caches."
  value       = module.frontend.deploy_commands
}
