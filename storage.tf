resource "google_storage_bucket" "dataproc_staging" {
  name                        = "my-dataproc-staging-bucket-${var.project_id}"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
}