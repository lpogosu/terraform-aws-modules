output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_version" {
  description = "Kubernetes version the control plane is actually running."
  value       = aws_eks_cluster.this.version
}

output "cluster_certificate_authority_data" {
  description = "Base64 PEM of the cluster CA, for the certificate-authority-data field of a kubeconfig."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group EKS created for the control plane. Node groups are placed in it automatically."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "cluster_iam_role_arn" {
  description = "ARN of the control plane IAM role."
  value       = aws_iam_role.cluster.arn
}

output "node_iam_role_arn" {
  description = "ARN of the shared node instance role."
  value       = aws_iam_role.node.arn
}

output "node_iam_role_name" {
  description = "Name of the shared node instance role. Needed to create an EKS access entry for the nodes under authentication_mode = API."
  value       = aws_iam_role.node.name
}

output "node_group_arns" {
  description = "Node group ARNs keyed by node group name."
  value       = { for name, ng in aws_eks_node_group.this : name => ng.arn }
}

output "node_group_capacity_types" {
  description = "Capacity type of each node group. Useful in a review: it shows at a glance what is running on SPOT."
  value       = { for name, ng in aws_eks_node_group.this : name => ng.capacity_type }
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider backing IRSA, or null when IRSA is disabled. This is the Federated principal of every IRSA role."
  value       = var.enable_irsa ? aws_iam_openid_connect_provider.irsa[0].arn : null
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL of the cluster."
  value       = local.oidc_issuer_url
}

output "oidc_issuer_host" {
  description = "OIDC issuer without the scheme. This is the prefix of the sub and aud condition keys in an IRSA trust policy."
  value       = local.oidc_issuer_host
}

output "secrets_kms_key_arn" {
  description = "KMS key used for envelope encryption of Secrets, or null when encryption is disabled."
  value       = local.secrets_kms_key_arn
}

output "addon_versions" {
  description = "Resolved version of each managed addon."
  value       = { for name, a in aws_eks_addon.this : name => a.addon_version }
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name}"
}
