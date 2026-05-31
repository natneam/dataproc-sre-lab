# List of APIs required for this deployment
variable "required_apis" {
  type = list(string)
  default = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dataproc.googleapis.com"
  ]
}

# Declaratively enable the APIs
resource "google_project_service" "enabled_apis" {
  for_each = toset(var.required_apis)
  project  = var.project_id
  service  = each.key

  disable_on_destroy = false
}