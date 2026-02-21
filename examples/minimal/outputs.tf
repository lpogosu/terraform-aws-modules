output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs, in the order of var.azs."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs, in the order of var.azs."
  value       = module.network.private_subnet_ids
}

output "intra_subnet_ids" {
  description = "Intra subnet IDs, in the order of var.azs."
  value       = module.network.intra_subnet_ids
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT gateways, keyed by availability zone. These are the addresses a partner allow-lists."
  value       = module.network.nat_public_ips
}

output "flow_log_group_name" {
  description = "CloudWatch log group holding the flow logs."
  value       = module.network.flow_log_group_name
}
