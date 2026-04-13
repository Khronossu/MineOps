variable "project" {
  type = string
}

variable "environment" {
  type = string
}

variable "region" {
  type = string
}

variable "account_id" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "minecraft_sg_id" {
  type = string
}

variable "efs_id" {
  type = string
}

variable "efs_access_point_id" {
  type = string
}

variable "mod_bucket_name" {
  type = string
}

variable "jvm_min_mem" {
  type = string
}

variable "jvm_max_mem" {
  type = string
}
