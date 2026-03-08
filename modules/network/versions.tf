terraform {
  # 1.9 is the floor because several modules here reference another variable from inside
  # a `validation` block (single_nat_gateway looks at enable_nat_gateway, the subnet lists
  # look at azs). Earlier releases reject that at parse time, not at plan time.
  required_version = ">= 1.9.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}
