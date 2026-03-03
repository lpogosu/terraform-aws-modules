variable "cluster_name" {
  description = "Name of the EKS cluster. Also the prefix of every IAM role, KMS alias and log group the module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,99}$", var.cluster_name))
    error_message = "cluster_name must be at most 100 chars of letters, digits and hyphens, starting with a letter or digit."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane, for example \"1.31\". Node groups follow it unless they override it."
  type        = string

  validation {
    condition     = can(regex("^1\\.(2[0-9]|[3-9][0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be a minor version such as 1.30 or 1.31, without a patch component."
  }
}

variable "subnet_ids" {
  description = "Subnets the control plane places its cross-account network interfaces in, and the default subnets for node groups. At least two availability zones."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "control_plane_subnet_ids" {
  description = "Override the subnets used by the control plane only. Empty list means reuse subnet_ids."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.control_plane_subnet_ids) == 0 || length(var.control_plane_subnet_ids) >= 2
    error_message = "control_plane_subnet_ids must be empty or cover at least two availability zones."
  }
}

variable "endpoint_private_access" {
  description = "Expose the Kubernetes API on a private endpoint inside the VPC."
  type        = bool
  default     = true
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API on a public endpoint. Off by default; turn it on only together with a narrow public_access_cidrs."
  type        = bool
  default     = false

  validation {
    condition     = var.endpoint_private_access || var.endpoint_public_access
    error_message = "At least one endpoint must be enabled, otherwise nothing can reach the API server."
  }
}

variable "public_access_cidrs" {
  description = "Source ranges allowed to reach the public endpoint. Ignored while endpoint_public_access is false."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry of public_access_cidrs must be a valid IPv4 CIDR block."
  }

  validation {
    condition     = !var.endpoint_public_access || length(var.public_access_cidrs) > 0
    error_message = "A public endpoint with an empty public_access_cidrs means 0.0.0.0/0. List the office and CI ranges explicitly."
  }
}

variable "cluster_security_group_ids" {
  description = "Extra security groups attached to the control plane network interfaces, on top of the one EKS creates."
  type        = list(string)
  default     = []
}

variable "enabled_cluster_log_types" {
  description = <<-EOT
    Control plane components whose logs are published to CloudWatch. `audit` and
    `authenticator` are the two that answer "who did this"; the rest are for debugging the
    control plane itself and are noticeably more expensive.
  EOT
  type        = list(string)
  default     = ["api", "audit", "authenticator"]

  validation {
    condition = alltrue([
      for t in var.enabled_cluster_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "Log types must be from api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "cluster_log_retention_days" {
  description = <<-EOT
    Retention of /aws/eks/<cluster>/cluster. The module creates this log group itself: left
    to EKS it is created with retention set to Never Expire, and audit logs then accumulate
    for the lifetime of the account.
  EOT
  type        = number
  default     = 90

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.cluster_log_retention_days
    )
    error_message = "cluster_log_retention_days must be one of the retention periods CloudWatch supports."
  }
}

variable "create_kms_key" {
  description = "Create a customer-managed KMS key for envelope encryption of Kubernetes Secrets."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Existing KMS key for envelope encryption. Used when create_kms_key is false; null then disables encryption of Secrets entirely."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "kms_key_deletion_window_days" {
  description = "Waiting period before a scheduled key deletion takes effect. Deleting the key makes every Secret in etcd unreadable, so the window is the last chance to notice."
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

variable "authentication_mode" {
  description = "How the cluster resolves identities: API (EKS access entries), API_AND_CONFIG_MAP, or CONFIG_MAP (the legacy aws-auth ConfigMap)."
  type        = string
  default     = "API_AND_CONFIG_MAP"

  validation {
    condition     = contains(["API", "API_AND_CONFIG_MAP", "CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be API, API_AND_CONFIG_MAP or CONFIG_MAP."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Give the principal running apply cluster-admin. Convenient on day one, and an invisible standing grant afterwards."
  type        = bool
  default     = false
}

variable "service_ipv4_cidr" {
  description = "CIDR the cluster allocates Service IPs from. Null lets EKS pick 172.20.0.0/16, which collides with a surprising number of corporate networks."
  type        = string
  default     = null

  validation {
    condition     = var.service_ipv4_cidr == null ? true : can(cidrhost(var.service_ipv4_cidr, 0))
    error_message = "service_ipv4_cidr must be a valid IPv4 CIDR block."
  }
}

variable "enable_irsa" {
  description = "Register the cluster OIDC issuer as an IAM identity provider so pods can assume roles through service accounts."
  type        = bool
  default     = true
}

variable "node_groups" {
  description = <<-EOT
    Managed node groups, keyed by name. The key becomes the node group name, so it is part
    of the resource address in state: renaming a key replaces the group.

    `capacity_type = "SPOT"` requires more than one instance type. A SPOT group pinned to a
    single type draws from a single capacity pool, and when that pool is reclaimed every
    node in the group goes at once.
  EOT

  type = map(object({
    subnet_ids         = optional(list(string), [])
    instance_types     = optional(list(string), ["t3.large"])
    capacity_type      = optional(string, "ON_DEMAND")
    ami_type           = optional(string, "AL2023_x86_64_STANDARD")
    disk_size          = optional(number, 50)
    kubernetes_version = optional(string)
    min_size           = number
    max_size           = number
    desired_size       = number
    max_unavailable    = optional(number, 1)
    labels             = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
    tags = optional(map(string), {})
  }))
  default = {}

  validation {
    condition = alltrue([
      for name in keys(var.node_groups) : can(regex("^[a-zA-Z0-9][a-zA-Z0-9-_]{0,62}$", name))
    ])
    error_message = "Node group names must be at most 63 chars of letters, digits, hyphens and underscores."
  }

  validation {
    condition     = alltrue([for g in var.node_groups : contains(["ON_DEMAND", "SPOT"], g.capacity_type)])
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups : g.min_size <= g.desired_size && g.desired_size <= g.max_size
    ])
    error_message = "Each node group must satisfy min_size <= desired_size <= max_size."
  }

  validation {
    condition     = alltrue([for g in var.node_groups : g.max_size >= 1])
    error_message = "max_size must be at least 1."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups : g.capacity_type != "SPOT" || length(g.instance_types) >= 2
    ])
    error_message = "A SPOT node group must list at least two instance types so it draws from more than one capacity pool."
  }

  validation {
    condition     = alltrue([for g in var.node_groups : length(g.instance_types) > 0])
    error_message = "Every node group must list at least one instance type."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups : alltrue([
        for t in g.taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], t.effect)
      ])
    ])
    error_message = "Taint effect must be NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE (the EKS API spelling, not the kubectl one)."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups : g.disk_size >= 20
    ])
    error_message = "disk_size must be at least 20 GiB; container images and logs fill anything smaller within weeks."
  }

  validation {
    condition = alltrue([
      for g in var.node_groups : g.max_unavailable >= 1 && g.max_unavailable <= g.max_size
    ])
    error_message = "max_unavailable must be between 1 and max_size."
  }
}

variable "node_role_additional_policy_arns" {
  description = "Extra managed policies for the shared node role, beyond the three EKS requires. Prefer IRSA over adding anything here."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.node_role_additional_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", a))])
    error_message = "Every entry must be an IAM policy ARN."
  }
}

variable "addons" {
  description = <<-EOT
    EKS managed addons, keyed by addon name (`vpc-cni`, `coredns`, `kube-proxy`,
    `aws-ebs-csi-driver`). A null `version` lets EKS pick the default for the cluster
    version, which is what you want unless you are pinning around a known bug.
  EOT

  type = map(object({
    version                     = optional(string)
    service_account_role_arn    = optional(string)
    configuration_values        = optional(string)
    resolve_conflicts_on_create = optional(string, "OVERWRITE")
    resolve_conflicts_on_update = optional(string, "PRESERVE")
    preserve                    = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for a in var.addons : contains(["OVERWRITE", "NONE"], a.resolve_conflicts_on_create)
    ])
    error_message = "resolve_conflicts_on_create must be OVERWRITE or NONE."
  }

  validation {
    condition = alltrue([
      for a in var.addons : contains(["OVERWRITE", "NONE", "PRESERVE"], a.resolve_conflicts_on_update)
    ])
    error_message = "resolve_conflicts_on_update must be OVERWRITE, NONE or PRESERVE."
  }
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}
