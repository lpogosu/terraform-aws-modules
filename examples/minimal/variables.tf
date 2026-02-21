variable "region" {
  description = "AWS region everything is created in."
  type        = string
  default     = "eu-central-1"
}

variable "name" {
  description = "Name prefix for the VPC and everything in it."
  type        = string
  default     = "sandbox"
}

variable "cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "azs" {
  description = "Availability zones to spread the subnets over."
  type        = list(string)
  default     = ["eu-central-1a", "eu-central-1b"]
}

variable "single_nat_gateway" {
  description = "Route both private subnets through one NAT gateway. True here because this example is a sandbox."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource through the provider default_tags block."
  type        = map(string)
  default = {
    managed-by = "terraform"
    example    = "minimal"
  }
}
