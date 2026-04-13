terraform {
  backend "s3" {
    bucket         = "aws-autoscale-stack-tf-state-amogh"
    key            = "aws-autoscale-stack/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "aws-autoscale-stack-tf-locks"
    encrypt        = true
  }
}
