locals {
  # /20 per public and private subnet leaves 4091 usable addresses each, which is enough
  # for a node group that grows without anyone recalculating the plan. Intra subnets hold
  # database endpoints and stay small.
  public_cidrs  = [for i, az in var.azs : cidrsubnet(var.cidr_block, 4, i)]
  private_cidrs = [for i, az in var.azs : cidrsubnet(var.cidr_block, 4, i + 4)]
  intra_cidrs   = [for i, az in var.azs : cidrsubnet(var.cidr_block, 8, i + 128)]
}

module "network" {
  source = "../../modules/network"

  name       = var.name
  cidr_block = var.cidr_block
  azs        = var.azs

  public_subnet_cidrs  = local.public_cidrs
  private_subnet_cidrs = local.private_cidrs
  intra_subnet_cidrs   = local.intra_cidrs

  single_nat_gateway = var.single_nat_gateway

  flow_log_traffic_type   = "REJECT"
  flow_log_retention_days = 30

  tags = var.tags
}
