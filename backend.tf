terraform {
  backend "gcs" {
    prefix = "terraform/state"
    # bucket is supplied via backend.hcl (gitignored) — see backend.hcl.example
  }
}