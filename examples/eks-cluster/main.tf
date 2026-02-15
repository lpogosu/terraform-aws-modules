data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  public_cidrs  = [for i, az in var.azs : cidrsubnet(var.cidr_block, 4, i)]
  private_cidrs = [for i, az in var.azs : cidrsubnet(var.cidr_block, 4, i + 4)]

  public_endpoint = length(var.api_access_cidrs) > 0
}

module "network" {
  source = "../../modules/network"

  name       = var.cluster_name
  cidr_block = var.cidr_block
  azs        = var.azs

  public_subnet_cidrs  = local.public_cidrs
  private_subnet_cidrs = local.private_cidrs

  single_nat_gateway = var.single_nat_gateway

  # The AWS Load Balancer Controller picks subnets by tag, not by configuration. Without
  # these two tags a Service of type LoadBalancer stays Pending with an event that says
  # "could not find any subnets" and nothing else.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }

  tags = var.tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version

  subnet_ids = module.network.private_subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = local.public_endpoint
  public_access_cidrs     = var.api_access_cidrs

  # API access entries instead of the aws-auth ConfigMap: a mistake in the ConfigMap locks
  # everyone out of the cluster and the only way back in is the creator principal.
  authentication_mode = "API_AND_CONFIG_MAP"

  enabled_cluster_log_types  = ["api", "audit", "authenticator"]
  cluster_log_retention_days = 90

  create_kms_key = true

  node_groups = {
    # Ingress controllers, metrics, log shippers. On demand and fixed size: these are the
    # pods whose eviction takes the observability of the incident with them.
    system = {
      instance_types = ["m7g.large"]
      ami_type       = "AL2023_ARM_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      disk_size      = 50

      min_size     = 3
      max_size     = 3
      desired_size = 3

      labels = {
        "workload" = "system"
      }

      taints = [{
        key    = "workload"
        value  = "system"
        effect = "NO_SCHEDULE"
      }]
    }

    # Application workloads on SPOT. Four instance types of comparable size, so the group
    # draws from four capacity pools instead of one: a reclaim event in a single pool takes
    # a quarter of the nodes rather than all of them.
    workers = {
      instance_types = ["m7i.large", "m6i.large", "m5.large", "m5a.large"]
      capacity_type  = "SPOT"
      disk_size      = 100

      min_size     = var.workers_min
      max_size     = var.workers_max
      desired_size = var.workers_min

      max_unavailable = 1

      labels = {
        "workload"                     = "application"
        "node.kubernetes.io/lifecycle" = "spot"
      }
    }
  }

  addons = {
    # vpc-cni first: nothing schedules until pods get addresses.
    vpc-cni    = {}
    kube-proxy = {}
    coredns    = {}
  }

  tags = var.tags
}

module "ci_role" {
  source = "../../modules/iam-github-oidc"

  role_name            = "${var.cluster_name}-github-deploy"
  create_oidc_provider = var.ci_create_oidc_provider

  repositories = {
    (var.ci_repository) = {
      # Only the default branch and only through the `production` environment, which is
      # where the required reviewers live. A pull request from a fork gets no credentials.
      refs         = ["refs/heads/main"]
      environments = ["production"]
    }
  }

  # One hour is IAM's floor for a role. The workflow asks for less than that itself -
  # configure-aws-credentials takes role-duration-seconds, and 900 is the floor there.
  max_session_duration = 3600

  policy_statements = [
    {
      sid       = "DescribeCluster"
      actions   = ["eks:DescribeCluster", "eks:ListClusters"]
      resources = [module.eks.cluster_arn]
    },
    {
      sid     = "AssumeClusterAdmin"
      actions = ["sts:AssumeRole"]
      # The pipeline gets a foothold, not cluster-admin. What it can do inside Kubernetes
      # is decided by the EKS access entry below, not by IAM. The ARN is composed rather
      # than referenced: aws_iam_role.deployer trusts this role, and referencing it back
      # here would close the dependency graph into a cycle.
      resources = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.cluster_name}-deployer"]
    },
  ]

  tags = var.tags
}

data "aws_iam_policy_document" "deployer_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [module.ci_role.role_arn]
    }
  }
}

# The identity the pipeline switches into to talk to Kubernetes. It carries no IAM policy
# at all: everything it may do lives in the EKS access entry, which is reviewed next to
# the cluster's RBAC instead of next to the account's IAM.
resource "aws_iam_role" "deployer" {
  name                 = "${var.cluster_name}-deployer"
  description          = "Kubernetes-side identity of the deploy pipeline"
  assume_role_policy   = data.aws_iam_policy_document.deployer_assume.json
  max_session_duration = 3600

  tags = var.tags
}

resource "aws_eks_access_entry" "deployer" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.deployer.arn
  type          = "STANDARD"
}

# Namespace-scoped edit rights, not AmazonEKSClusterAdminPolicy. A pipeline that deploys
# the application has no business editing ClusterRoleBindings.
resource "aws_eks_access_policy_association" "deployer" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.deployer.arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = var.deploy_namespaces
  }

  depends_on = [aws_eks_access_entry.deployer]
}
