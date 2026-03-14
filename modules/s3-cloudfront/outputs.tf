output "bucket_id" {
  description = "Name of the origin bucket."
  value       = aws_s3_bucket.origin.id
}

output "bucket_arn" {
  description = "ARN of the origin bucket. Grant the deploy role s3:PutObject on \"<arn>/*\"."
  value       = aws_s3_bucket.origin.arn
}

output "bucket_regional_domain_name" {
  description = "Regional endpoint of the origin bucket, which is what CloudFront is pointed at."
  value       = aws_s3_bucket.origin.bucket_regional_domain_name
}

output "log_bucket_id" {
  description = "Name of the access log bucket, or null when logging is disabled."
  value       = var.enable_logging ? aws_s3_bucket.logs[0].id : null
}

output "distribution_id" {
  description = "CloudFront distribution ID. This is the argument of `aws cloudfront create-invalidation`."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_arn" {
  description = "ARN of the distribution. The origin bucket policy is scoped to exactly this value."
  value       = aws_cloudfront_distribution.this.arn
}

output "distribution_domain_name" {
  description = "The <id>.cloudfront.net name of the distribution."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "Hosted zone ID of the distribution, for a Route 53 alias record."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}

output "origin_access_control_id" {
  description = "ID of the Origin Access Control signing the origin requests."
  value       = aws_cloudfront_origin_access_control.this.id
}

output "deploy_commands" {
  description = "Sync the site and invalidate the edge caches. The invalidation is the step people forget."
  value = join("\n", [
    "aws s3 sync ./dist s3://${aws_s3_bucket.origin.id} --delete",
    "aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.this.id} --paths '/*'",
  ])
}
