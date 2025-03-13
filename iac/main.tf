terraform {
  required_version = "= 1.11.1"

  backend "s3" {
    bucket  = "★★★replace_me★★★"
    key     = "athena-etl/terraform.tfstate"
    profile = "athena-etl"
    region  = "ap-northeast-1"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 5.90.1"
    }
  }
}

provider "aws" {
  profile = "athena-etl"
  region  = "ap-northeast-1"
  default_tags {
    tags = {
      TerraformDefaultTag = "created_by_terraform"
    }
  }
}
