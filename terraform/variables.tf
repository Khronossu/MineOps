variable "region" {
  description = "AWS region"
  type        = string
  default     = "ap-southeast-1"
}

variable "environment" {
  description = "Environment name (dev or prod)"
  type        = string
}

variable "project_name" {
  description = "Project name used for resource naming"
  type        = string
  default     = "mineops"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "mod_bucket_name" {
  description = "S3 bucket name for mod profiles"
  type        = string
}

variable "jvm_min_mem" {
  description = "JVM minimum heap size"
  type        = string
  default     = "1G"
}

variable "jvm_max_mem" {
  description = "JVM maximum heap size"
  type        = string
  default     = "3G"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for purinboonpetch.com"
  type        = string
}

variable "domain_name" {
  description = "Subdomain for the Minecraft server"
  type        = string
  default     = "play.purinboonpetch.com"
}
