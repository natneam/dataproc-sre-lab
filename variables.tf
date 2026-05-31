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

variable "dataproc_sa" {
  type        = string
  default      = "dataproc-worker-sa"
  description  = "Dedicated service account for Dataproc master and worker instances"
}