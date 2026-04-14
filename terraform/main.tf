terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "networking" {
  source       = "./modules/networking"
  project_name = var.project_name
  aws_region   = var.aws_region
}

module "alb" {
  source            = "./modules/alb"
  project_name      = var.project_name
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
}

module "asg" {
  source                 = "./modules/asg"
  project_name           = var.project_name
  aws_region             = var.aws_region
  app_ami_id             = var.app_ami_id
  nginx_ami_id           = var.nginx_ami_id
  vpc_id                 = module.networking.vpc_id
  private_subnet_ids     = module.networking.private_subnet_ids
  public_subnet_ids      = module.networking.public_subnet_ids
  alb_target_group_arn   = module.alb.alb_target_group_arn
  alb_sg_id              = module.alb.alb_sg_id
  ssm_s3_bucket          = "aws-autoscale-stack-tf-state-amogh"
  db_username            = var.db_username
  db_password            = var.db_password
  app_bootstrap_repo_url = var.app_bootstrap_repo_url
  app_bootstrap_repo_ref = var.app_bootstrap_repo_ref
}

module "database" {
  source             = "./modules/database"
  project_name       = var.project_name
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  app_sg_id          = module.asg.app_sg_id
  db_username        = var.db_username
  db_password        = var.db_password
}
