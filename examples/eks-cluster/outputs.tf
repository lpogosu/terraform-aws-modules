output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Command that writes a kubeconfig entry for this cluster."
  value       = module.eks.kubeconfig_command
}

output "oidc_provider_arn" {
  description = "IAM OIDC provider backing IRSA. The Federated principal of every IRSA trust policy."
  value       = module.eks.oidc_provider_arn
}

output "oidc_issuer_host" {
  description = "Issuer without the scheme, the prefix of the sub and aud condition keys in an IRSA trust policy."
  value       = module.eks.oidc_issuer_host
}

output "node_group_capacity_types" {
  description = "Capacity type of each node group, so a review can see what runs on SPOT."
  value       = module.eks.node_group_capacity_types
}

output "secrets_kms_key_arn" {
  description = "KMS key performing envelope encryption of Kubernetes Secrets."
  value       = module.eks.secrets_kms_key_arn
}

output "ci_role_arn" {
  description = "Role GitHub Actions assumes. Goes into role-to-assume in the workflow."
  value       = module.ci_role.role_arn
}

output "ci_trusted_subjects" {
  description = "Exact sub claims the CI role accepts."
  value       = module.ci_role.trusted_subjects
}

output "nat_public_ips" {
  description = "Egress addresses of the cluster, keyed by availability zone."
  value       = module.network.nat_public_ips
}

output "deployer_role_arn" {
  description = "Role the CI role switches into to talk to Kubernetes. Bound to the cluster by an EKS access entry."
  value       = aws_iam_role.deployer.arn
}
