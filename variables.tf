variable "project_id" {
  type        = string
  description = "The GCP Project ID where resources will be deployed"
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "The primary region for the network infrastructure"
}

variable "custom_vpc" {
  type        = string
  default     = "my-custom-vpc"
  description = "The custom VPC network to use for Dataproc resources"
}

variable "secure_subnet" {
  type        = string
  default     = "my-secure-subnet"
  description = "The secure subnet to use for Dataproc resources"
}

variable "router" {
  type        = string
  default     = "my-cloud-router"
  description = "The cloud router to use for Dataproc resources"
}

variable "nat" {
  type        = string
  default     = "my-nat"
  description = "The NAT gateway to use for Dataproc resources"
}

variable "allow_internal" {
  type        = string
  default     = "allow-internal"
  description = "The name of the firewall rule to allow internal traffic"
}

variable "dataproc_sa" {
  type        = string
  default     = "dataproc-worker-sa"
  description = "Dedicated service account for Dataproc master and worker instances"
}

variable "dataproc_cluster_name" {
  type        = string
  default     = "secure-dataproc-cluster"
  description = "The name of the Dataproc cluster"
}

variable "dataproc_master_num_instances" {
  type        = number
  default     = 1
  description = "The number of master instances for the Dataproc cluster"

  validation {
    condition     = contains([1, 3], var.dataproc_master_num_instances)
    error_message = "The dataproc_master_num_instances must be exactly 1 or 3 (High-Avialability)"
  }
}
variable "dataproc_master_machine_type" {
  type        = string
  default     = "n1-standard-2"
  description = "The machine type for the Dataproc master instance"
}
variable "dataproc_worker_num_instances" {
  type        = number
  default     = 2
  description = "The number of worker instances for the Dataproc cluster"
}
variable "dataproc_worker_machine_type" {
  type        = string
  default     = "n1-standard-2"
  description = "The machine type for the Dataproc worker instances"
}

variable "dataproc_preemptible_worker_num_instances" {
  type        = number
  default     = 2
  description = "The number of preemptible worker instances for the Dataproc cluster"
}

variable "dataproc_preemptible_worker_boot_disk_size" {
  type        = number
  default     = 50
  description = "The boot disk size for the Dataproc preemptible worker instances"
}

variable "dataproc_preemptible_worker_boot_disk_type" {
  type        = string
  default     = "pd-standard"
  description = "The boot disk type for the Dataproc preemptible worker instances"
}

variable "dataproc_software_image_version" {
  type        = string
  default     = "2.1-debian11"
  description = "The software image version for the Dataproc cluster"
}

variable "dataproc_queue_fast_burn_promql" {
  type        = string
  default     = "Dataproc Queue Fast Burn Alert"
  description = "The Prometheus query for the fast burn queue"
}

variable "email_address" {
  type        = string
  description = "The email address for the notification channel"
}
