variable "region" {
  description = "AWS region everything except the CloudFront certificate is created in."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Name prefix for the VPC, the database and the security groups."
  type        = string
  default     = "shop"
}

variable "cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
  default     = "10.40.0.0/16"
}

variable "azs" {
  description = "Availability zones the subnets are spread over."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "bucket_name" {
  description = "Globally unique name of the bucket serving the static frontend."
  type        = string
}

variable "aliases" {
  description = "Alternate domain names on the distribution. Needs acm_certificate_arn."
  type        = list(string)
  default     = []
}

variable "acm_certificate_arn" {
  description = "ACM certificate for the aliases, in us-east-1. Null serves the site on the *.cloudfront.net name."
  type        = string
  default     = null
}

variable "engine_version" {
  description = "PostgreSQL major version."
  type        = string
  default     = "16"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.medium"
}

variable "multi_az" {
  description = "Run a synchronous standby in a second zone. True for anything holding orders."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Refuse to delete the database. Turn off explicitly to tear the environment down."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource through the provider default_tags block."
  type        = map(string)
  default = {
    managed-by = "terraform"
    example    = "web-app"
  }
}
