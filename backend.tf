terraform {
  backend "gcs" {
    bucket = "REDACTED"
    prefix = "terraform/state"
  }
}