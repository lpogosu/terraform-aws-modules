variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9+=,.@_-]{1,64}$", var.role_name))
    error_message = "role_name must be at most 64 characters from the IAM name alphabet [a-zA-Z0-9+=,.@_-]."
  }
}

variable "create_oidc_provider" {
  description = <<-EOT
    Create the token.actions.githubusercontent.com identity provider. There can be only one
    per AWS account, so set this to false and pass `oidc_provider_arn` in every account that
    already has it.
  EOT
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of an existing GitHub OIDC provider. Required when create_oidc_provider is false, ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.oidc_provider_arn == null ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/", var.oidc_provider_arn))
    error_message = "oidc_provider_arn must be an IAM OIDC provider ARN, for example arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com."
  }

  validation {
    condition     = var.create_oidc_provider || var.oidc_provider_arn != null
    error_message = "oidc_provider_arn must be set when create_oidc_provider is false."
  }
}

variable "oidc_thumbprints" {
  description = <<-EOT
    Certificate thumbprints of the GitHub OIDC endpoint. Leave empty: since provider 5.x
    Terraform fetches the current thumbprint itself, and a hardcoded one silently expires
    when GitHub rotates its intermediate CA.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.oidc_thumbprints : can(regex("^[0-9a-fA-F]{40}$", t))])
    error_message = "Every thumbprint must be a 40-character hex SHA-1 fingerprint."
  }
}

variable "repositories" {
  description = <<-EOT
    Repositories allowed to assume the role, keyed by `owner/name`. Each entry lists the
    claims that are accepted, and at least one of them must be non-empty:

      refs         - `refs/heads/main`, `refs/tags/v*`; matched against the `ref` subject
      environments - GitHub Environment names; use these when the environment has reviewers
      pull_request - accept the synthetic `pull_request` subject of a PR-triggered run

    Wildcards are allowed inside a claim but the claim itself is never optional: a role
    whose trust policy ends at `repo:owner/name:*` is assumable from any branch, and any
    branch includes the one an attacker just pushed.
  EOT

  type = map(object({
    refs         = optional(list(string), [])
    environments = optional(list(string), [])
    pull_request = optional(bool, false)
  }))

  validation {
    condition     = length(var.repositories) > 0
    error_message = "At least one repository must be listed, otherwise the role is assumable by nobody."
  }

  validation {
    condition = alltrue([
      for repo in keys(var.repositories) : can(regex("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$", repo))
    ])
    error_message = "Repository keys must be owner/name with no wildcard, for example lpogosu/terraform-aws-modules."
  }

  validation {
    condition = alltrue([
      for repo, cfg in var.repositories :
      length(cfg.refs) + length(cfg.environments) + (cfg.pull_request ? 1 : 0) > 0
    ])
    error_message = "Every repository must accept at least one of refs, environments or pull_request."
  }

  validation {
    condition = alltrue([
      for repo, cfg in var.repositories : alltrue([
        for r in cfg.refs : startswith(r, "refs/")
      ])
    ])
    error_message = "Refs must be fully qualified, for example refs/heads/main or refs/tags/v*. A bare branch name never matches the sub claim."
  }

  validation {
    condition = alltrue([
      for repo, cfg in var.repositories : alltrue([
        for r in cfg.refs : r != "refs/*" && r != "*"
      ])
    ])
    error_message = "A ref pattern of refs/* or * trusts every branch in the repository, which defeats the point of scoping the role."
  }
}

variable "policy_statements" {
  description = <<-EOT
    Inline policy the role carries. Written as statements rather than raw JSON so the
    module can refuse an obviously over-broad one before it reaches IAM.
  EOT

  type = list(object({
    sid       = string
    effect    = optional(string, "Allow")
    actions   = list(string)
    resources = list(string)
    conditions = optional(list(object({
      test     = string
      variable = string
      values   = list(string)
    })), [])
  }))
  default = []

  validation {
    condition     = alltrue([for s in var.policy_statements : contains(["Allow", "Deny"], s.effect)])
    error_message = "Statement effect must be Allow or Deny."
  }

  validation {
    condition     = alltrue([for s in var.policy_statements : length(s.actions) > 0 && length(s.resources) > 0])
    error_message = "Every statement must list at least one action and at least one resource."
  }

  validation {
    condition = alltrue([
      for s in var.policy_statements :
      s.effect == "Deny" || !(contains(s.actions, "*") && contains(s.resources, "*"))
    ])
    error_message = "An Allow statement of \"*\" on \"*\" is administrator access. Name the actions the pipeline actually needs."
  }

  validation {
    condition     = length(distinct([for s in var.policy_statements : s.sid])) == length(var.policy_statements)
    error_message = "Statement sids must be unique inside one policy."
  }
}

variable "managed_policy_arns" {
  description = "Customer or AWS managed policies attached to the role in addition to the inline statements."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.managed_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", a))])
    error_message = "Every entry of managed_policy_arns must be an IAM policy ARN."
  }
}

variable "max_session_duration" {
  description = <<-EOT
    Ceiling on how long the credentials the workflow receives stay valid, in seconds.
    IAM's floor for a role is one hour - 900 seconds is the floor of the AssumeRole call,
    not of the role - so a shorter session is requested by the caller, not configured here.
  EOT
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 and 43200 seconds. IAM rejects anything below one hour for a role."
  }
}

variable "permissions_boundary" {
  description = "Optional permissions boundary policy ARN. A ceiling the role cannot exceed even if its own policy is widened later."
  type        = string
  default     = null

  validation {
    condition     = var.permissions_boundary == null ? true : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/", var.permissions_boundary))
    error_message = "permissions_boundary must be an IAM policy ARN."
  }
}

variable "audience" {
  description = "Value the aud claim must carry. Leave at sts.amazonaws.com unless the workflow overrides the audience when requesting its token."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "tags" {
  description = "Tags applied to every resource the module creates."
  type        = map(string)
  default     = {}
}
