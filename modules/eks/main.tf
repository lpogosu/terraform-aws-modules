data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  control_plane_subnets = length(var.control_plane_subnet_ids) > 0 ? var.control_plane_subnet_ids : var.subnet_ids

  secrets_kms_key_arn = var.create_kms_key ? aws_kms_key.secrets[0].arn : var.kms_key_arn
  encrypt_secrets     = local.secrets_kms_key_arn != null

  # The OIDC issuer URL carries the https:// scheme; the IAM provider resource wants it
  # with the scheme, the sub/aud condition keys want it without. Both forms are derived
  # once here so the difference cannot be got wrong twice.
  oidc_issuer_url  = try(aws_eks_cluster.this.identity[0].oidc[0].issuer, null)
  oidc_issuer_host = local.oidc_issuer_url == null ? null : replace(local.oidc_issuer_url, "https://", "")

  policy_prefix = "arn:${data.aws_partition.current.partition}:iam::aws:policy"

  common_tags = merge(var.tags, { Name = var.cluster_name })
}

# --- Control plane IAM ------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "${local.policy_prefix}/AmazonEKSClusterPolicy",
    # Required for security groups for pods; without it the control plane cannot manage
    # the branch network interfaces and SecurityGroupPolicy silently does nothing.
    "${local.policy_prefix}/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# --- Envelope encryption for Secrets -----------------------------------------------------

# An explicit key policy rather than the default one. The default grants the whole account
# root full control and says nothing about who may use the key, so every audit of "who can
# read Secrets" ends in reading IAM policies across the account instead of one document.
data "aws_iam_policy_document" "secrets_key" {
  # The three skips below are the same misreading: checkov scores this as an identity
  # policy, where `Resource: "*"` means every resource in the account. It is a KMS key
  # policy, and there `Resource: "*"` means this key and nothing else - KMS rejects a key
  # policy that names any other resource. The scoping that matters here is in Principal.
  # checkov:skip=CKV_AWS_111:key policy, "*" is the key itself
  # checkov:skip=CKV_AWS_356:key policy, "*" is the key itself
  # checkov:skip=CKV_AWS_109:key policy, "*" is the key itself
  count = var.create_kms_key ? 1 : 0

  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid    = "AllowControlPlaneEnvelopeEncryption"
    effect = "Allow"

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      # The control plane creates a grant per cluster; without CreateGrant the cluster
      # comes up and then fails every Secret write with an opaque KMS error.
      "kms:CreateGrant",
    ]

    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.cluster.arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.enabled_cluster_log_types) > 0 ? [1] : []

    content {
      sid    = "AllowCloudWatchLogsEncryption"
      effect = "Allow"

      actions = [
        "kms:Encrypt*",
        "kms:Decrypt*",
        "kms:ReEncrypt*",
        "kms:GenerateDataKey*",
        "kms:Describe*",
      ]

      resources = ["*"]

      principals {
        type        = "Service"
        identifiers = ["logs.${data.aws_region.current.name}.amazonaws.com"]
      }

      # Scoped to this cluster's log group. Without the encryption context condition the
      # log service can use the key for any log group in the account.
      condition {
        test     = "ArnEquals"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values = [
          "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${var.cluster_name}/cluster",
        ]
      }
    }
  }
}

resource "aws_kms_key" "secrets" {
  count = var.create_kms_key ? 1 : 0

  description             = "Envelope encryption of Kubernetes Secrets for ${var.cluster_name}"
  deletion_window_in_days = var.kms_key_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.secrets_key[0].json

  tags = merge(var.tags, { Name = "${var.cluster_name}-secrets" })
}

resource "aws_kms_alias" "secrets" {
  count = var.create_kms_key ? 1 : 0

  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

# --- Control plane -----------------------------------------------------------------------

# Created before the cluster so the log group exists with a retention policy. EKS creates
# it on first write otherwise, with retention set to Never Expire.
resource "aws_cloudwatch_log_group" "cluster" {
  # checkov:skip=CKV_AWS_338:90 days, not 365. A year of EKS audit logs is one of the larger
  #   lines on a CloudWatch bill, and the retention regimes that require a year also require
  #   the logs to leave CloudWatch for cheaper storage. cluster_log_retention_days is an input.
  count = length(var.enabled_cluster_log_types) > 0 ? 1 : 0

  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_days

  # Only the key this module created, never one passed in through kms_key_arn. CloudWatch
  # Logs can encrypt with a key whose policy names logs.<region>.amazonaws.com, and the
  # module writes that statement itself; an external key most likely has no such statement,
  # and the failure surfaces as a create error on the log group rather than a warning.
  kms_key_id = var.create_kms_key ? aws_kms_key.secrets[0].arn : null

  tags = local.common_tags
}

resource "aws_eks_cluster" "this" {
  # checkov:skip=CKV_AWS_39:endpoint_public_access defaults to false. A library module has
  #   to be able to express a public endpoint - some teams reach the API from a hosted CI
  #   runner and have nowhere to put a bastion - so the switch exists and defaults to off.
  # checkov:skip=CKV_AWS_38:public_access_cidrs has a validation block that refuses an empty
  #   list while the public endpoint is enabled, which is exactly the 0.0.0.0/0 case. checkov
  #   cannot see a variable validation, so it assumes the worst.
  # checkov:skip=CKV_AWS_37:controllerManager and scheduler logs are off by default. They
  #   answer questions about the control plane itself, which AWS operates, and they are the
  #   two noisiest streams. enabled_cluster_log_types turns them on where they are needed.
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.cluster.arn

  enabled_cluster_log_types = var.enabled_cluster_log_types

  vpc_config {
    subnet_ids              = local.control_plane_subnets
    security_group_ids      = var.cluster_security_group_ids
    endpoint_private_access = var.endpoint_private_access
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions
  }

  dynamic "kubernetes_network_config" {
    for_each = var.service_ipv4_cidr == null ? [] : [var.service_ipv4_cidr]

    content {
      service_ipv4_cidr = kubernetes_network_config.value
    }
  }

  # Without this block Secrets are stored in etcd encrypted only by the EBS volume key,
  # which every EKS cluster in the region shares the properties of. With it each Secret
  # gets a data key wrapped by a key this account controls and can revoke.
  dynamic "encryption_config" {
    for_each = local.encrypt_secrets ? [local.secrets_kms_key_arn] : []

    content {
      resources = ["secrets"]

      provider {
        key_arn = encryption_config.value
      }
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# --- IRSA --------------------------------------------------------------------------------

# The thumbprint is deliberately not pinned: provider 5.x fetches the current one from the
# issuer. A hardcoded thumbprint is a time bomb that goes off when AWS rotates the CA.
resource "aws_iam_openid_connect_provider" "irsa" {
  count = var.enable_irsa ? 1 : 0

  url            = local.oidc_issuer_url
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(var.tags, { Name = "${var.cluster_name}-irsa" })
}

# --- Node IAM ----------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset(concat([
    "${local.policy_prefix}/AmazonEKSWorkerNodePolicy",
    "${local.policy_prefix}/AmazonEC2ContainerRegistryReadOnly",
    # The CNI plugin runs as a DaemonSet on the node and needs to attach ENIs. This is the
    # one workload-level permission that genuinely belongs on the instance role.
    "${local.policy_prefix}/AmazonEKS_CNI_Policy",
  ], var.node_role_additional_policy_arns))

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "this" {
  for_each = var.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = length(each.value.subnet_ids) > 0 ? each.value.subnet_ids : var.subnet_ids

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  ami_type       = each.value.ami_type
  disk_size      = each.value.disk_size
  version        = coalesce(each.value.kubernetes_version, var.kubernetes_version)
  labels         = each.value.labels

  scaling_config {
    min_size     = each.value.min_size
    max_size     = each.value.max_size
    desired_size = each.value.desired_size
  }

  update_config {
    max_unavailable = each.value.max_unavailable
  }

  dynamic "taint" {
    for_each = each.value.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # desired_size is the autoscaler's to own after the group exists. Without this, every
  # plan after a scale-up wants to shrink the group back to the number in the code.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = merge(var.tags, each.value.tags, { Name = "${var.cluster_name}-${each.key}" })

  depends_on = [aws_iam_role_policy_attachment.node]
}

# --- Addons ------------------------------------------------------------------------------

# Addons are created after the node groups: coredns stays Degraded until it has somewhere
# to schedule, and a Degraded addon fails the apply rather than converging later.
resource "aws_eks_addon" "this" {
  for_each = var.addons

  cluster_name  = aws_eks_cluster.this.name
  addon_name    = each.key
  addon_version = each.value.version

  service_account_role_arn    = each.value.service_account_role_arn
  configuration_values        = each.value.configuration_values
  resolve_conflicts_on_create = each.value.resolve_conflicts_on_create
  resolve_conflicts_on_update = each.value.resolve_conflicts_on_update
  preserve                    = each.value.preserve

  tags = merge(var.tags, { Name = "${var.cluster_name}-${each.key}" })

  depends_on = [aws_eks_node_group.this]
}
