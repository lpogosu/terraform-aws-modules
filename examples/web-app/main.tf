locals {
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

  # Production topology: one NAT gateway per zone, so a zone failure costs that zone and
  # nothing else.
  single_nat_gateway = false

  tags = var.tags
}

# The application tier is not part of this library - ECS services, EC2 instances or an EKS
# cluster all fit here. What the example does own is the security group they attach to,
# because it is the identity the database ingress rule is written against.
resource "aws_security_group" "app" {
  # checkov:skip=CKV2_AWS_5:deliberately attached to nothing here. The application tier is
  #   out of scope for this library, and the group exists so the database ingress rule can
  #   name a stable identity instead of a CIDR that changes with the network layout.
  name        = "${var.name}-app"
  description = "Application tier of ${var.name}"
  vpc_id      = module.network.vpc_id

  tags = { Name = "${var.name}-app" }
}

resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "Package registries, container registries and the AWS API"
}

resource "aws_vpc_security_group_egress_rule" "app_postgres" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = module.database.security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL"
}

module "database" {
  source = "../../modules/rds"

  identifier = "${var.name}-pg"
  vpc_id     = module.network.vpc_id

  # Intra subnets, not private: the database has no reason to reach the internet, and a
  # subnet with no default route makes that structural rather than a matter of policy.
  subnet_ids = module.network.intra_subnet_ids

  engine_version         = var.engine_version
  parameter_group_family = "postgres${var.engine_version}"
  instance_class         = var.instance_class

  allocated_storage     = 100
  max_allocated_storage = 500
  multi_az              = var.multi_az

  database_name   = "shop"
  master_username = "shop_admin"

  allowed_security_group_ids = [aws_security_group.app.id]

  backup_retention_period = 14
  backup_window           = "01:00-02:00"
  maintenance_window      = "sun:03:00-sun:05:00"

  deletion_protection = var.deletion_protection
  skip_final_snapshot = false

  performance_insights_enabled = true
  monitoring_interval          = 60

  parameters = {
    # Log anything slower than a second. The default of -1 logs nothing, which is how a
    # single unindexed query stays invisible until it takes the site down.
    "log_min_duration_statement" = { value = "1000" }
    "log_connections"            = { value = "1" }
    "log_disconnections"         = { value = "1" }
    # Static parameter: it allocates shared memory, so it only takes effect on reboot.
    "pg_stat_statements.max" = { value = "5000", apply_method = "pending-reboot" }
  }

  tags = var.tags
}

module "frontend" {
  source = "../../modules/s3-cloudfront"

  bucket_name = var.bucket_name

  versioning_enabled  = true
  aliases             = var.aliases
  acm_certificate_arn = var.acm_certificate_arn

  # Single-page application: the router lives in the bundle, so a deep link has to reach
  # index.html instead of an S3 error document.
  custom_error_responses = {
    "403" = { response_code = 200, response_page_path = "/index.html" }
    "404" = { response_code = 200, response_page_path = "/index.html" }
  }

  lifecycle_rules = {
    expire-old-bundles = {
      # Versioning keeps every superseded asset forever unless something removes it. Thirty
      # days is long enough to roll a release back and short enough to stay a rounding error.
      noncurrent_version_expiration_days = 30
      abort_incomplete_multipart_days    = 7
    }
  }

  enable_logging     = true
  log_retention_days = 90

  tags = var.tags
}
