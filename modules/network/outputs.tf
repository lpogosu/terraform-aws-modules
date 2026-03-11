output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_arn" {
  description = "ARN of the VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Availability zones the subnets are spread over."
  value       = var.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs in the order of var.azs. Suitable for internet-facing load balancers."
  value       = [for az in var.azs : aws_subnet.public[az].id if contains(keys(local.public_subnets), az)]
}

output "private_subnet_ids" {
  description = "Private subnet IDs in the order of var.azs. Suitable for EKS nodes and application instances."
  value       = [for az in var.azs : aws_subnet.private[az].id if contains(keys(local.private_subnets), az)]
}

output "intra_subnet_ids" {
  description = "Intra subnet IDs in the order of var.azs. No route to the internet in either direction."
  value       = [for az in var.azs : aws_subnet.intra[az].id if contains(keys(local.intra_subnets), az)]
}

output "public_subnets_by_az" {
  description = "Public subnet IDs keyed by availability zone."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnets_by_az" {
  description = "Private subnet IDs keyed by availability zone."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "intra_subnets_by_az" {
  description = "Intra subnet IDs keyed by availability zone."
  value       = { for az, s in aws_subnet.intra : az => s.id }
}

output "public_subnet_cidrs" {
  description = "IPv4 CIDR blocks of the public subnets, keyed by availability zone."
  value       = { for az, s in aws_subnet.public : az => s.cidr_block }
}

output "private_subnet_cidrs" {
  description = "IPv4 CIDR blocks of the private subnets, keyed by availability zone."
  value       = { for az, s in aws_subnet.private : az => s.cidr_block }
}

output "intra_subnet_cidrs" {
  description = "IPv4 CIDR blocks of the intra subnets, keyed by availability zone."
  value       = { for az, s in aws_subnet.intra : az => s.cidr_block }
}

output "internet_gateway_id" {
  description = "ID of the internet gateway, or null when no public subnet exists."
  value       = length(local.public_subnets) > 0 ? aws_internet_gateway.this[0].id : null
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by the availability zone they sit in. Empty when NAT is disabled."
  value       = { for az, ngw in aws_nat_gateway.this : az => ngw.id }
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT gateways. These are the source addresses partners have to allow-list."
  value       = { for az, eip in aws_eip.nat : az => eip.public_ip }
}

output "public_route_table_id" {
  description = "ID of the shared public route table, or null when no public subnet exists."
  value       = length(local.public_subnets) > 0 ? aws_route_table.public[0].id : null
}

output "private_route_table_ids" {
  description = "Private route table IDs keyed by availability zone. Needed to attach S3 and DynamoDB gateway endpoints."
  value       = { for az, rt in aws_route_table.private : az => rt.id }
}

output "intra_route_table_id" {
  description = "ID of the shared intra route table, or null when no intra subnet exists."
  value       = length(local.intra_subnets) > 0 ? aws_route_table.intra[0].id : null
}

output "default_security_group_id" {
  description = "ID of the VPC default security group. All of its rules are removed when manage_default_security_group is true."
  value       = aws_vpc.this.default_security_group_id
}

output "flow_log_group_name" {
  description = "Name of the CloudWatch log group receiving flow logs, or null when flow logs are disabled."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_log[0].name : null
}

output "flow_log_group_arn" {
  description = "ARN of the CloudWatch log group receiving flow logs, or null when flow logs are disabled."
  value       = var.enable_flow_logs ? aws_cloudwatch_log_group.flow_log[0].arn : null
}
