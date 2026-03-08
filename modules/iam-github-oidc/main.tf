locals {
  provider_url = "https://token.actions.githubusercontent.com"

  oidc_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.oidc_provider_arn

  # The sub claim GitHub puts in the token looks like
  #   repo:<owner>/<name>:ref:refs/heads/main
  #   repo:<owner>/<name>:environment:production
  #   repo:<owner>/<name>:pull_request
  # The trust policy matches this string, so the list below is the entire access control
  # decision for the role. Nothing later in the pipeline can widen it.
  subjects = flatten([
    for repo, cfg in var.repositories : concat(
      [for r in cfg.refs : "repo:${repo}:ref:${r}"],
      [for e in cfg.environments : "repo:${repo}:environment:${e}"],
      cfg.pull_request ? ["repo:${repo}:pull_request"] : [],
    )
  ])
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = local.provider_url
  client_id_list  = [var.audience]
  thumbprint_list = length(var.oidc_thumbprints) > 0 ? var.oidc_thumbprints : null

  tags = merge(var.tags, { Name = "github-actions" })
}

data "aws_iam_policy_document" "assume" {
  statement {
    sid     = "GitHubActionsWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    # Without the aud condition the role is assumable with a token minted for any
    # audience, including one issued to a completely unrelated cloud.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = [var.audience]
    }

    # StringLike rather than StringEquals so `refs/tags/v*` works. The patterns are built
    # from the repositories map, which forbids a bare `*`.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = "Assumed by GitHub Actions through OIDC web identity federation"
  assume_role_policy   = data.aws_iam_policy_document.assume.json
  max_session_duration = var.max_session_duration
  permissions_boundary = var.permissions_boundary

  tags = merge(var.tags, { Name = var.role_name })
}

data "aws_iam_policy_document" "inline" {
  count = length(var.policy_statements) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = var.policy_statements

    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources

      dynamic "condition" {
        for_each = statement.value.conditions

        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = condition.value.values
        }
      }
    }
  }
}

resource "aws_iam_role_policy" "inline" {
  count = length(var.policy_statements) > 0 ? 1 : 0

  name   = "${var.role_name}-inline"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.inline[0].json
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}
