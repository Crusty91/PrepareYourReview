provider "aws" {
    region = var.region
}

terraform {
  backend "s3" {
    bucket = var.backendbucket
    key    = var.backendkey
    region = var.backendregion
  }
}
