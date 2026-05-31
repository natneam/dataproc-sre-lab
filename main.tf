resource "google_dataproc_cluster" "secure_cluster" {
  name   = var.dataproc_cluster_name
  region = var.region
  cluster_config {
    # Storage Configuration
    staging_bucket = google_storage_bucket.dataproc_staging.name

    # Primary Master Node
    master_config {
      num_instances = var.dataproc_master_num_instances
      machine_type  = var.dataproc_master_machine_type

      disk_config {
        boot_disk_size_gb = 50
        boot_disk_type    = "pd-standard"
      }
    }

    # Primary Worker Nodes
    worker_config {
      num_instances = var.dataproc_worker_num_instances
      machine_type  = var.dataproc_worker_machine_type

      disk_config {
        boot_disk_size_gb = 50
        boot_disk_type    = "pd-standard"
      }
    }

    # Secondary Worker Nodes
    preemptible_worker_config {
      num_instances = var.dataproc_preemptible_worker_num_instances
      disk_config {
        boot_disk_size_gb = var.dataproc_preemptible_worker_boot_disk_size
        boot_disk_type    = var.dataproc_preemptible_worker_boot_disk_type
      }
    }

    software_config {
      image_version = var.dataproc_software_image_version
    }

    gce_cluster_config {
      subnetwork             = google_compute_subnetwork.secure_subnet.id
      service_account        = google_service_account.dataproc_sa.email
      service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
      internal_ip_only       = true
    }
  }

  # Wait until the Service Account IAM roles are fully established
  depends_on = [
    google_project_iam_member.dataproc_worker_binding,
    google_project_iam_member.storage_admin_binding
  ]
}
