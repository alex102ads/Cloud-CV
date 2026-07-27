# Terraform Backend Configuration
# This configures where Terraform stores its state file

# For local development, use local state
# For production/GitHub Actions, use S3 backend

# terraform {
#   backend "s3" {
#     bucket  = "cloud-cv-7893c044"
#     key     = "terraform/state.tfstate"
#     region  = "us-east-1"
#     encrypt = true
#   }
# }
