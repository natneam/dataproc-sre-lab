terraform {
  required_version = ">= 1.5.0" # Prevents older/incompatible TF versions from running

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0" # Keeps provider within the 7.x version range
    }
  }
}