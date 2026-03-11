locals {
  # Subnets are keyed by availability zone rather than by list index. A key change in a
  # for_each map touches one resource; an index shift in a count list renumbers everything
  # after it and Terraform plans to replace the lot.
  public_subnets  = { for i, az in var.azs : az => var.public_subnet_cidrs[i] if length(var.public_subnet_cidrs) > 0 }
  private_subnets = { for i, az in var.azs : az => var.private_subnet_cidrs[i] if length(var.private_subnet_cidrs) > 0 }
  intra_subnets   = { for i, az in var.azs : az => var.intra_subnet_cidrs[i] if length(var.intra_subnet_cidrs) > 0 }

  # A NAT gateway lives in a public subnet and only earns its cost if something private
  # needs to reach out. Without either side there is nothing to create.
  create_nat = var.enable_nat_gateway && length(local.public_subnets) > 0 && length(local.private_subnets) > 0
  nat_azs    = local.create_nat ? (var.single_nat_gateway ? [var.azs[0]] : keys(local.private_subnets)) : []

  # Private route tables stay one-per-zone in both modes. They are free, and keeping the
  # topology identical means flipping single_nat_gateway rewrites routes instead of
  # destroying and recreating route tables and their associations.
  nat_az_for = { for az in keys(local.private_subnets) : az => var.single_nat_gateway ? var.azs[0] : az }

  common_tags = merge(var.tags, { Name = var.name })
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = var.enable_dns_hostnames

  tags = local.common_tags
}

# AWS creates a security group with every VPC that allows all traffic between its members
# and cannot be deleted. Adopting it with no rules at all is the only way to make sure an
# instance launched without an explicit group ends up isolated instead of trusted.
resource "aws_default_security_group" "this" {
  count = var.manage_default_security_group ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-default-locked" })
}

resource "aws_internet_gateway" "this" {
  count = length(local.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(
    var.tags,
    var.public_subnet_tags,
    { Name = "${var.name}-public-${each.key}", Tier = "public" },
  )
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(
    var.tags,
    var.private_subnet_tags,
    { Name = "${var.name}-private-${each.key}", Tier = "private" },
  )
}

resource "aws_subnet" "intra" {
  for_each = local.intra_subnets

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value

  tags = merge(
    var.tags,
    var.intra_subnet_tags,
    { Name = "${var.name}-intra-${each.key}", Tier = "intra" },
  )
}

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  # `vpc = true` is deprecated in provider 5.x; the domain attribute replaced it.
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

# One public route table for the whole VPC: every public subnet needs exactly the same
# default route to the internet gateway, and per-zone copies would only add drift.
resource "aws_route_table" "public" {
  count = length(local.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  count = length(local.public_subnets) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

resource "aws_route_table_association" "public" {
  for_each = local.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  for_each = local.private_subnets

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-private-${each.key}" })
}

resource "aws_route" "private_default" {
  for_each = local.create_nat ? local.private_subnets : {}

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_az_for[each.key]].id
}

resource "aws_route_table_association" "private" {
  for_each = local.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.key].id
}

# Intra subnets share a single route table that never gets a default route. Adding one
# later is a visible one-line change rather than an accident of tagging.
resource "aws_route_table" "intra" {
  count = length(local.intra_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-intra" })
}

resource "aws_route_table_association" "intra" {
  for_each = local.intra_subnets

  subnet_id      = aws_subnet.intra[each.key].id
  route_table_id = aws_route_table.intra[0].id
}

resource "aws_cloudwatch_log_group" "flow_log" {
  # checkov:skip=CKV_AWS_338:90 days, not 365. Flow logs at ALL traffic are the highest
  #   volume log a VPC produces; a year of them in CloudWatch costs more than the NAT
  #   gateways they describe. flow_log_retention_days is an input for the cases that need it.
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.flow_log_kms_key_arn

  tags = local.common_tags
}

data "aws_iam_policy_document" "flow_log_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    # Scoped to the streams of this one log group. The delivery service asks for
    # logs:* on * in most examples, which hands it every log group in the account.
    resources = ["${aws_cloudwatch_log_group.flow_log[0].arn}:*"]
  }
}

resource "aws_iam_role" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_log_assume[0].json

  tags = local.common_tags
}

# A separate aws_iam_role_policy rather than the inline_policy block: the block is
# deprecated in provider 5.x and cannot be managed independently of the role.
resource "aws_iam_role_policy" "flow_log" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "publish-flow-logs"
  role   = aws_iam_role.flow_log[0].id
  policy = data.aws_iam_policy_document.flow_log[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = var.flow_log_traffic_type
  max_aggregation_interval = var.flow_log_max_aggregation_interval

  # log_group_name is deprecated; the destination is expressed as an ARN plus a type so
  # the same argument can point at S3 or Kinesis Firehose instead.
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_log[0].arn
  iam_role_arn         = aws_iam_role.flow_log[0].arn

  tags = local.common_tags
}
