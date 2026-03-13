locals {
  origin_id      = "s3-${var.bucket_name}"
  log_bucket     = coalesce(var.log_bucket_name, "${var.bucket_name}-logs")
  common_tags    = merge(var.tags, { Name = var.bucket_name })
  use_custom_tls = var.acm_certificate_arn != null
}

# CachingOptimized: honours Cache-Control from the origin, forwards no cookies and no
# query string into the cache key. Looked up by name rather than pasted as a UUID.
data "aws_cloudfront_cache_policy" "optimized" {
  count = var.cache_policy_id == null ? 1 : 0

  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_response_headers_policy" "security" {
  count = var.response_headers_policy_id == null ? 1 : 0

  name = "Managed-SecurityHeadersPolicy"
}

# --- Origin bucket -----------------------------------------------------------------------

resource "aws_s3_bucket" "origin" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = local.common_tags
}

# Every inline setting on aws_s3_bucket (acl, versioning, logging, lifecycle_rule, the
# encryption block) is deprecated in provider 4.x and later. The separate resources below
# are the supported form and, unlike the inline blocks, do not fight with settings changed
# outside Terraform.
resource "aws_s3_bucket_public_access_block" "origin" {
  bucket = aws_s3_bucket.origin.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# BucketOwnerEnforced switches ACLs off entirely. With Origin Access Control the only
# thing that grants read access is the bucket policy, so there is nothing an ACL could
# usefully say.
resource "aws_s3_bucket_ownership_controls" "origin" {
  bucket = aws_s3_bucket.origin.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "origin" {
  bucket = aws_s3_bucket.origin.id

  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "origin" {
  bucket = aws_s3_bucket.origin.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # With SSE-KMS this collapses the per-object Decrypt calls into one per bucket per
    # short interval. It is the difference between a workable KMS bill and a surprising one.
    bucket_key_enabled = var.kms_key_arn != null
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "origin" {
  # checkov:skip=CKV_AWS_300:the abort_incomplete_multipart_upload block is emitted from a
  #   dynamic block driven by var.lifecycle_rules. checkov does not unroll dynamic blocks, so
  #   it reads a rule that sets the field as a rule that does not.
  count = length(var.lifecycle_rules) > 0 ? 1 : 0

  bucket = aws_s3_bucket.origin.id

  dynamic "rule" {
    for_each = var.lifecycle_rules

    content {
      id     = rule.key
      status = rule.value.enabled ? "Enabled" : "Disabled"

      # A rule with no filter at all is accepted but warned about, and the prefix argument
      # on the rule itself is deprecated. An empty prefix filter means "every object".
      filter {
        prefix = rule.value.prefix
      }

      dynamic "abort_incomplete_multipart_upload" {
        for_each = rule.value.abort_incomplete_multipart_days == null ? [] : [rule.value.abort_incomplete_multipart_days]

        content {
          days_after_initiation = abort_incomplete_multipart_upload.value
        }
      }

      dynamic "expiration" {
        for_each = rule.value.expiration_days == null ? [] : [rule.value.expiration_days]

        content {
          days = expiration.value
        }
      }

      dynamic "noncurrent_version_expiration" {
        for_each = rule.value.noncurrent_version_expiration_days == null ? [] : [rule.value.noncurrent_version_expiration_days]

        content {
          noncurrent_days           = noncurrent_version_expiration.value
          newer_noncurrent_versions = rule.value.noncurrent_versions_to_keep
        }
      }

      dynamic "transition" {
        for_each = rule.value.transitions

        content {
          days          = transition.value.days
          storage_class = transition.value.storage_class
        }
      }

      dynamic "noncurrent_version_transition" {
        for_each = rule.value.noncurrent_version_transitions

        content {
          noncurrent_days = noncurrent_version_transition.value.days
          storage_class   = noncurrent_version_transition.value.storage_class
        }
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.origin]
}

# --- Log bucket --------------------------------------------------------------------------

resource "aws_s3_bucket" "logs" {
  # The four skips below share one cause: every companion resource for this bucket carries
  # `count`, and checkov's graph does not follow a `count`-indexed reference back to the
  # bucket. The same companions on the origin bucket, which has no count, are found and pass.
  # checkov:skip=CKV_AWS_21:versioning is configured in aws_s3_bucket_versioning.logs
  # checkov:skip=CKV2_AWS_61:lifecycle is configured in aws_s3_bucket_lifecycle_configuration.logs
  # checkov:skip=CKV2_AWS_6:public access is blocked in aws_s3_bucket_public_access_block.logs
  # checkov:skip=CKV_AWS_145:SSE-S3, not SSE-KMS, and deliberately. The CloudFront log
  #   delivery service cannot write into a bucket encrypted with a customer-managed key;
  #   logs simply stop arriving, with no error surfaced anywhere.
  count = var.enable_logging ? 1 : 0

  bucket        = local.log_bucket
  force_destroy = var.force_destroy

  tags = merge(var.tags, { Name = local.log_bucket })
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudFront standard logging still writes through an ACL grant to the awslogsdelivery
# canonical user. BucketOwnerEnforced would switch ACLs off and the delivery would fail
# with no error visible anywhere in the CloudFront console, so the log bucket - and only
# the log bucket - keeps BucketOwnerPreferred.
resource "aws_s3_bucket_ownership_controls" "logs" {
  # checkov:skip=CKV2_AWS_65:this is the one bucket in the repository that must keep ACLs.
  #   The reason is the comment directly above; BucketOwnerEnforced here breaks log delivery.
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  # SSE-S3 rather than SSE-KMS: the log delivery service cannot write to a bucket
  # encrypted with a customer-managed key.
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "expire-access-logs"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.logs]
}

# --- CloudFront ---------------------------------------------------------------------------

# Origin Access Control, not the legacy Origin Access Identity: OAC signs the origin
# request with SigV4, which is what makes SSE-KMS origins and non-GET methods work at all.
resource "aws_cloudfront_origin_access_control" "this" {
  name                              = var.bucket_name
  description                       = "SigV4 access from CloudFront to ${var.bucket_name}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "this" {
  # checkov:skip=CKV_AWS_374:geo restriction defaults to none. A blanket country allow-list
  #   on a library module would be a guess about someone else's audience; the inputs are
  #   there and the module refuses a whitelist with no countries in it.
  # checkov:skip=CKV_AWS_310:origin failover needs a second origin. This module has exactly
  #   one, an S3 bucket, and S3 already replicates within the region - a failover group
  #   pointing at the same data in the same region buys nothing.
  # checkov:skip=CKV2_AWS_47:no WAF by default. web_acl_id is an input, and a WAFv2 ACL is
  #   a regional resource in us-east-1 with its own rule groups and its own bill; creating
  #   one implicitly from a CDN module would be the wrong place for that decision.
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Private S3 origin ${var.bucket_name}"
  default_root_object = var.default_root_object
  price_class         = var.price_class
  aliases             = var.aliases
  web_acl_id          = var.web_acl_id
  http_version        = "http2and3"

  origin {
    # The regional domain name, not the global one: the global endpoint redirects with a
    # 307 to the regional one for a bucket created in the last 24 hours, and a signed
    # request does not survive the redirect.
    domain_name              = aws_s3_bucket.origin.bucket_regional_domain_name
    origin_id                = local.origin_id
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  default_cache_behavior {
    target_origin_id       = local.origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    cache_policy_id            = coalesce(var.cache_policy_id, try(data.aws_cloudfront_cache_policy.optimized[0].id, null))
    response_headers_policy_id = coalesce(var.response_headers_policy_id, try(data.aws_cloudfront_response_headers_policy.security[0].id, null))
  }

  dynamic "custom_error_response" {
    for_each = var.custom_error_responses

    content {
      error_code            = tonumber(custom_error_response.key)
      response_code         = custom_error_response.value.response_code
      response_page_path    = custom_error_response.value.response_page_path
      error_caching_min_ttl = custom_error_response.value.error_caching_min_ttl
    }
  }

  dynamic "logging_config" {
    for_each = var.enable_logging ? [1] : []

    content {
      bucket          = aws_s3_bucket.logs[0].bucket_domain_name
      prefix          = "cloudfront/"
      include_cookies = false
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = var.geo_restriction_type
      locations        = var.geo_restriction_locations
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_custom_tls ? null : true
    acm_certificate_arn            = var.acm_certificate_arn
    ssl_support_method             = local.use_custom_tls ? "sni-only" : null
    minimum_protocol_version       = local.use_custom_tls ? var.minimum_protocol_version : null
  }

  tags = local.common_tags

  depends_on = [aws_s3_bucket_ownership_controls.logs]
}

# --- Bucket policy -------------------------------------------------------------------------

data "aws_iam_policy_document" "origin" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.origin.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    # Scoped to this one distribution. Without the SourceArn condition the statement
    # grants read to every CloudFront distribution in every AWS account.
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.origin.arn, "${aws_s3_bucket.origin.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "origin" {
  bucket = aws_s3_bucket.origin.id
  policy = data.aws_iam_policy_document.origin.json

  # The public access block must exist first; applying a policy to a bucket whose block is
  # created in the same plan can trip block_public_policy on the initial evaluation.
  depends_on = [aws_s3_bucket_public_access_block.origin]
}

data "aws_iam_policy_document" "logs" {
  count = var.enable_logging ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs[0].arn, "${aws_s3_bucket.logs[0].arn}/*"]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  count = var.enable_logging ? 1 : 0

  bucket = aws_s3_bucket.logs[0].id
  policy = data.aws_iam_policy_document.logs[0].json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}
