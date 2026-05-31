# Create Custom Service Account
resource "google_service_account" "dataproc_sa" {
  account_id   = var.dataproc_sa
  display_name = "Dataproc Worker SA"
  description  = "Dedicated service account for Dataproc master and worker instances"
}

# Grant Dataproc Worker IAM Role to the Service Account
resource "google_project_iam_member" "dataproc_worker_binding" {
  project = var.project_id
  role    = "roles/dataproc.worker"
  member  = "serviceAccount:${google_service_account.dataproc_sa.email}"
}

# Grant Storage Object Admin IAM Role to the Service Account
resource "google_project_iam_member" "storage_admin_binding" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.dataproc_sa.email}"
}