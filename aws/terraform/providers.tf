terraform {
  required_version = "~> 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "serverless-vod-tfstate-950672314674"
    key          = "serverless-vod/terraform.tfstate"
    region       = "sa-east-1"
    profile      = "default"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  aws_profile = terraform.workspace == "cliente" ? "cliente" : "default"
  aws_region  = "sa-east-1"
}

provider "aws" {
  region  = local.aws_region
  profile = local.aws_profile
}
