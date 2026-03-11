variable "name" {
  description = "Prefix for every resource name and the Name tag of the VPC."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3-32 chars, lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  type        = string

  validation {
    condition     = can(cidrhost(var.cidr_block, 0))
    error_message = "cidr_block must be a valid IPv4 CIDR block, for example 10.0.0.0/16."
  }

  validation {
    # /16 is the largest VPC AWS accepts, /28 the smallest that leaves usable addresses
    # after the five AWS reserves in every subnet.
    condition     = can(regex("/(1[6-9]|2[0-8])$", var.cidr_block))
    error_message = "VPC prefix length must be between /16 and /28."
  }
}

variable "azs" {
  description = "Availability zone names to spread the subnets over, for example [\"eu-central-1a\", \"eu-central-1b\"]."
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 1 && length(var.azs) <= 6
    error_message = "Between 1 and 6 availability zones must be listed."
  }

  validation {
    condition     = length(distinct(var.azs)) == length(var.azs)
    error_message = "azs must not repeat an availability zone."
  }
}

variable "public_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for the public subnets, one per entry of `azs` and in the same order.
    An empty list creates no public subnets, and with them no internet gateway and no NAT.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.public_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry of public_subnet_cidrs must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = length(var.public_subnet_cidrs) == 0 || length(var.public_subnet_cidrs) == length(var.azs)
    error_message = "public_subnet_cidrs must be empty or hold exactly one CIDR per availability zone."
  }
}

variable "private_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for the private subnets, one per entry of `azs` and in the same order.
    These are the subnets that reach the internet through NAT.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.private_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry of private_subnet_cidrs must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = length(var.private_subnet_cidrs) == 0 || length(var.private_subnet_cidrs) == length(var.azs)
    error_message = "private_subnet_cidrs must be empty or hold exactly one CIDR per availability zone."
  }
}

variable "intra_subnet_cidrs" {
  description = <<-EOT
    CIDR blocks for the intra subnets, one per entry of `azs` and in the same order.
    Intra subnets get a route table with no default route at all: nothing in them can reach
    the internet, and nothing on the internet can reach them. Databases and cache clusters
    belong here.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.intra_subnet_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry of intra_subnet_cidrs must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = length(var.intra_subnet_cidrs) == 0 || length(var.intra_subnet_cidrs) == length(var.azs)
    error_message = "intra_subnet_cidrs must be empty or hold exactly one CIDR per availability zone."
  }
}

variable "enable_nat_gateway" {
  description = "Create NAT gateways so the private subnets can make outbound connections."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = <<-EOT
    Put one NAT gateway in the first availability zone and route every private subnet
    through it, instead of one gateway per zone. Cuts the hourly charge to 1/N, and makes
    the loss of that one zone an outage for every private subnet. Non-production only.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.single_nat_gateway || var.enable_nat_gateway
    error_message = "single_nat_gateway has no meaning while enable_nat_gateway is false."
  }
}

variable "enable_dns_hostnames" {
  description = "Assign public DNS hostnames to instances with a public IP. Required by EKS and by RDS private endpoints."
  type        = bool
  default     = true
}

variable "map_public_ip_on_launch" {
  description = <<-EOT
    Give every instance launched into a public subnet a public IPv4 address automatically.
    Off by default: load balancers and NAT gateways bring their own addresses, so turning
    this on mostly hands public IPs to instances that were never meant to have one.
  EOT
  type        = bool
  default     = false
}

variable "manage_default_security_group" {
  description = <<-EOT
    Adopt the security group AWS creates with the VPC and strip every rule from it.
    The default group allows unrestricted traffic between its own members, and anything
    launched without an explicit group lands in it.
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to a CloudWatch log group created by this module."
  type        = bool
  default     = true
}

variable "flow_log_traffic_type" {
  description = "Which flows to record: ACCEPT, REJECT or ALL."
  type        = string
  default     = "ALL"

  validation {
    condition     = contains(["ACCEPT", "REJECT", "ALL"], var.flow_log_traffic_type)
    error_message = "flow_log_traffic_type must be one of ACCEPT, REJECT, ALL."
  }
}

variable "flow_log_retention_days" {
  description = "Retention of the flow log group. Must be one of the values CloudWatch accepts."
  type        = number
  default     = 90

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.flow_log_retention_days
    )
    error_message = "flow_log_retention_days must be one of the retention periods CloudWatch supports (1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653)."
  }
}

variable "flow_log_max_aggregation_interval" {
  description = "Seconds a flow is aggregated before being published: 60 or 600. 60 costs more and shows short-lived connections."
  type        = number
  default     = 600

  validation {
    condition     = contains([60, 600], var.flow_log_max_aggregation_interval)
    error_message = "flow_log_max_aggregation_interval must be 60 or 600."
  }
}

variable "flow_log_kms_key_arn" {
  description = <<-EOT
    Customer-managed KMS key encrypting the flow log group. Null leaves CloudWatch on its
    service-managed key, which is still encryption at rest but not one you can revoke.
  EOT
  type        = string
  default     = null

  validation {
    # `||` in HCL evaluates both operands, so a null check has to be a conditional:
    # `var.x == null || can(...)` would still run the regex against null.
    condition     = var.flow_log_kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:", var.flow_log_kms_key_arn))
    error_message = "flow_log_kms_key_arn must be a KMS key ARN, for example arn:aws:kms:eu-central-1:111122223333:key/<uuid>."
  }
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}

variable "public_subnet_tags" {
  description = "Extra tags for the public subnets only. EKS discovers internet-facing load balancer subnets through kubernetes.io/role/elb."
  type        = map(string)
  default     = {}
}

variable "private_subnet_tags" {
  description = "Extra tags for the private subnets only. EKS discovers internal load balancer subnets through kubernetes.io/role/internal-elb."
  type        = map(string)
  default     = {}
}

variable "intra_subnet_tags" {
  description = "Extra tags for the intra subnets only."
  type        = map(string)
  default     = {}
}
