variable "region" {
  description = "AWS region everything is created in."
  type        = string
  default     = "eu-central-1"
}

variable "cluster_name" {
  description = "Cluster name. Also the prefix of the VPC, the IAM roles and the CI role."
  type        = string
  default     = "platform"
}

variable "cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
  default     = "10.30.0.0/16"
}

variable "azs" {
  description = "Availability zones. Three is the smallest number that survives losing one without halving capacity."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane and the node groups."
  type        = string
  default     = "1.31"
}

variable "single_nat_gateway" {
  description = "Route every private subnet through one NAT gateway. Leave false for a cluster that is expected to stay up."
  type        = bool
  default     = false
}

variable "api_access_cidrs" {
  description = "Source ranges allowed to reach the public Kubernetes API endpoint. Empty list keeps the endpoint private only."
  type        = list(string)
  default     = []
}

variable "workers_min" {
  description = "Lower bound of the SPOT worker pool."
  type        = number
  default     = 2
}

variable "workers_max" {
  description = "Upper bound of the SPOT worker pool."
  type        = number
  default     = 10
}

variable "ci_repository" {
  description = "GitHub repository, as owner/name, whose workflows may assume the deploy role."
  type        = string
  default     = "lpogosu/terraform-aws-modules"
}

variable "ci_create_oidc_provider" {
  description = "Create the GitHub OIDC provider. False in an account that already has one, since IAM allows only a single provider per issuer."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource through the provider default_tags block."
  type        = map(string)
  default = {
    managed-by = "terraform"
    example    = "eks-cluster"
  }
}

variable "deploy_namespaces" {
  description = "Kubernetes namespaces the deploy role may edit. The access entry is scoped to these and nothing else."
  type        = list(string)
  default     = ["default", "payments"]

  validation {
    condition     = length(var.deploy_namespaces) > 0
    error_message = "A namespace-scoped access entry with no namespaces grants nothing; list at least one."
  }
}
