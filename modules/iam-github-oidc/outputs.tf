output "role_arn" {
  description = "ARN of the role. This is the value that goes into role-to-assume in the workflow."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the role."
  value       = aws_iam_role.this.name
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider, whether this module created it or it was passed in."
  value       = local.oidc_arn
}

output "trusted_subjects" {
  description = "Exact sub claims the trust policy accepts. Read this in a review instead of decoding the policy JSON."
  value       = local.subjects
}

output "workflow_snippet" {
  description = "The permissions block and the configure-aws-credentials step a workflow needs to use this role."
  value       = <<-EOT
    permissions:
      id-token: write
      contents: read

    steps:
      - uses: aws-actions/configure-aws-credentials@v4.0.2
        with:
          role-to-assume: ${aws_iam_role.this.arn}
          aws-region: <region>
  EOT
}
