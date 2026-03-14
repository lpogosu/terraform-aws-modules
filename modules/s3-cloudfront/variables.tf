variable "bucket_name" {
  description = "Name of the origin bucket. Globally unique across all AWS accounts."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 chars of lowercase letters, digits, dots and hyphens, starting and ending with a letter or digit."
  }

  validation {
    condition     = !can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.bucket_name))
    error_message = "A bucket name that looks like an IP address is rejected by S3."
  }

  validation {
    # A dot in the name breaks the virtual-hosted-style TLS certificate, which is exactly
    # the endpoint CloudFront uses to reach the origin.
    condition     = !strcontains(var.bucket_name, ".")
    error_message = "Avoid dots in a bucket used as a CloudFront origin: the wildcard certificate on *.s3.<region>.amazonaws.com does not cover a name with a dot in it."
  }
}

variable "force_destroy" {
  description = "Allow `terraform destroy` to delete a bucket that still holds objects. Off by default."
  type        = bool
  default     = false
}

variable "versioning_enabled" {
  description = "Keep previous versions of every object. This is what makes a bad deploy recoverable without a backup job."
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = <<-EOT
    KMS key encrypting objects at rest. Null uses SSE-S3 (AES256).

    SSE-KMS on a CloudFront origin means every cache miss is a KMS Decrypt call, billed and
    rate limited. It is the right choice for private data and the wrong one for a public
    static site, which is why the module does not pick for you.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null ? true : can(regex("^arn:aws[a-z-]*:kms:", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN."
  }
}

variable "lifecycle_rules" {
  description = <<-EOT
    Lifecycle rules, keyed by rule ID. Every rule must actually do something: a rule with
    no transition and no expiry is accepted by S3, shows up as enabled, and deletes nothing.

    `noncurrent_version_expiration_days` is the one that matters on a versioned bucket.
    Without it, every overwritten object is kept forever and the bill grows in a line item
    nobody looks at.
  EOT

  type = map(object({
    prefix                             = optional(string, "")
    enabled                            = optional(bool, true)
    abort_incomplete_multipart_days    = optional(number)
    expiration_days                    = optional(number)
    noncurrent_version_expiration_days = optional(number)
    noncurrent_versions_to_keep        = optional(number)
    transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
    noncurrent_version_transitions = optional(list(object({
      days          = number
      storage_class = string
    })), [])
  }))
  default = {}

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules :
      r.abort_incomplete_multipart_days != null
      || r.expiration_days != null
      || r.noncurrent_version_expiration_days != null
      || length(r.transitions) > 0
      || length(r.noncurrent_version_transitions) > 0
    ])
    error_message = "A lifecycle rule that sets no expiry and no transition does nothing. Give it an action or remove it."
  }

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules : alltrue([
        for t in concat(r.transitions, r.noncurrent_version_transitions) :
        contains(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"], t.storage_class)
      ])
    ])
    error_message = "Transition storage_class must be one of STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER_IR, GLACIER, DEEP_ARCHIVE."
  }

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules :
      r.expiration_days == null ? true : r.expiration_days > 0
    ])
    error_message = "expiration_days must be greater than zero."
  }

  validation {
    condition = alltrue([
      for r in var.lifecycle_rules : alltrue([
        for t in r.transitions :
        r.expiration_days == null ? true : t.days < r.expiration_days
      ])
    ])
    error_message = "A transition scheduled on or after the expiry never happens. Move the transition earlier or push the expiry out."
  }
}

variable "aliases" {
  description = "Alternate domain names served by the distribution. Requires acm_certificate_arn."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.aliases : can(regex("^(\\*\\.)?([a-z0-9-]+\\.)+[a-z]{2,}$", a))])
    error_message = "Every alias must be a DNS name, optionally with a leading *. wildcard label."
  }
}

variable "acm_certificate_arn" {
  description = "ACM certificate for the aliases. Must live in us-east-1: CloudFront reads certificates from that region only, whatever region the rest of the stack is in."
  type        = string
  default     = null

  validation {
    condition     = var.acm_certificate_arn == null ? true : can(regex("^arn:aws[a-z-]*:acm:us-east-1:[0-9]{12}:certificate/", var.acm_certificate_arn))
    error_message = "acm_certificate_arn must be an ACM certificate ARN in us-east-1."
  }

  validation {
    condition     = length(var.aliases) == 0 || var.acm_certificate_arn != null
    error_message = "Aliases need a certificate. The default CloudFront certificate only covers *.cloudfront.net."
  }
}

variable "minimum_protocol_version" {
  description = "Lowest TLS version accepted from viewers. Only applies while a custom certificate is attached."
  type        = string
  default     = "TLSv1.2_2021"

  validation {
    condition     = contains(["TLSv1.2_2018", "TLSv1.2_2019", "TLSv1.2_2021"], var.minimum_protocol_version)
    error_message = "minimum_protocol_version must be one of the TLSv1.2 policies. Anything older is TLS 1.0 or 1.1."
  }
}

variable "default_root_object" {
  description = "Object returned for a request to the distribution root."
  type        = string
  default     = "index.html"
}

variable "price_class" {
  description = "Edge locations the distribution uses: PriceClass_100 (NA + EU), PriceClass_200 (adds Asia), PriceClass_All."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "cache_policy_id" {
  description = "Cache policy for the default behaviour. Null looks up the AWS managed CachingOptimized policy."
  type        = string
  default     = null
}

variable "response_headers_policy_id" {
  description = "Response headers policy, for HSTS and the other security headers. Null looks up the AWS managed SecurityHeadersPolicy."
  type        = string
  default     = null
}

variable "geo_restriction_type" {
  description = "Geographic restriction: none, whitelist or blacklist."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "whitelist", "blacklist"], var.geo_restriction_type)
    error_message = "geo_restriction_type must be none, whitelist or blacklist."
  }
}

variable "geo_restriction_locations" {
  description = "ISO 3166-1 alpha-2 country codes the restriction applies to."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.geo_restriction_locations : can(regex("^[A-Z]{2}$", c))])
    error_message = "Country codes must be two uppercase letters, for example DE."
  }

  validation {
    condition     = var.geo_restriction_type == "none" || length(var.geo_restriction_locations) > 0
    error_message = "A whitelist or blacklist restriction with no countries either blocks everything or nothing. List the countries."
  }
}

variable "custom_error_responses" {
  description = <<-EOT
    Error responses rewritten at the edge, keyed by the status code CloudFront received.
    A single-page application maps 403 and 404 to /index.html with response code 200;
    without that, a deep link reloads into an S3 error document.
  EOT

  type = map(object({
    response_code         = number
    response_page_path    = string
    error_caching_min_ttl = optional(number, 10)
  }))
  default = {}

  validation {
    condition = alltrue([
      for code in keys(var.custom_error_responses) : can(regex("^[45][0-9]{2}$", code))
    ])
    error_message = "Keys must be 4xx or 5xx status codes."
  }

  validation {
    condition = alltrue([
      for r in var.custom_error_responses : startswith(r.response_page_path, "/")
    ])
    error_message = "response_page_path must start with a slash."
  }
}

variable "enable_logging" {
  description = "Create a second bucket and send CloudFront standard access logs to it."
  type        = bool
  default     = false
}

variable "log_bucket_name" {
  description = "Name of the log bucket. Null derives it from bucket_name."
  type        = string
  default     = null

  validation {
    condition     = var.log_bucket_name == null ? true : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.log_bucket_name))
    error_message = "log_bucket_name must be a valid S3 bucket name."
  }
}

variable "log_retention_days" {
  description = "Days access logs are kept before the lifecycle rule expires them."
  type        = number
  default     = 90

  validation {
    condition     = var.log_retention_days >= 1
    error_message = "log_retention_days must be at least 1."
  }
}

variable "web_acl_id" {
  description = "ARN of a WAFv2 web ACL to attach. The ACL must be created in us-east-1 with scope CLOUDFRONT."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}
