terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "first-demo-bucket-purin-boonpetch"
    key     = "minecraft/terraform.tfstate"
    region  = "ap-southeast-2"
    encrypt = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "MineOps"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

module "network" {
  source      = "./modules/network"
  project     = var.project_name
  environment = var.environment
  vpc_cidr    = var.vpc_cidr
  region      = var.region
}

module "storage" {
  source      = "./modules/storage"
  project     = var.project_name
  environment = var.environment
  bucket_name = var.mod_bucket_name
}

module "efs" {
  source            = "./modules/efs"
  project           = var.project_name
  environment       = var.environment
  vpc_id            = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  efs_sg_id         = module.network.efs_sg_id
}

module "ecs" {
  source              = "./modules/ecs"
  project             = var.project_name
  environment         = var.environment
  region              = var.region
  vpc_id              = module.network.vpc_id
  private_subnet_ids  = module.network.private_subnet_ids
  public_subnet_ids   = module.network.public_subnet_ids
  minecraft_sg_id     = module.network.minecraft_sg_id
  efs_id              = module.efs.efs_id
  efs_access_point_id = module.efs.access_point_id
  mod_bucket_name     = var.mod_bucket_name
  jvm_min_mem         = var.jvm_min_mem
  jvm_max_mem         = var.jvm_max_mem
  account_id          = data.aws_caller_identity.current.account_id
}

module "lambda" {
  source             = "./modules/lambda"
  project            = var.project_name
  environment        = var.environment
  region             = var.region
  account_id         = data.aws_caller_identity.current.account_id
  ecs_cluster_name   = module.ecs.cluster_name
  ecs_service_name   = module.ecs.service_name
  mod_bucket_name    = var.mod_bucket_name
  cloudflare_zone_id = var.cloudflare_zone_id
  domain_name        = var.domain_name
}

data "aws_caller_identity" "current" {}
