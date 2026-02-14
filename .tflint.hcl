config {
  # Every module is linted directly. Following module calls would report the same finding
  # once per example that happens to call the module.
  call_module_type = "none"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# The AWS ruleset knows the instance types, RDS classes and API argument values that
# actually exist. It catches a typo in db.t4g.medium before an apply spends four minutes
# discovering it, which no amount of provider schema validation does.
plugin "aws" {
  enabled = true
  version = "0.45.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# A module input is part of a published interface. Renaming one silently breaks callers,
# so the naming style is enforced rather than left to review.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_comment_syntax" {
  enabled = true
}

rule "terraform_module_version" {
  enabled = true
}
