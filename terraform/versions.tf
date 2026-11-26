terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }
}

locals {
  common_tags = {
    Project     = "aws-hybrid-healthcare"
    Company     = "Downrange Cloud"
    Owner       = "harold"
    Environment = "lab"
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}