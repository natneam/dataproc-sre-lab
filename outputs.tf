output "vpc_name" {
  value       = google_compute_network.custom_vpc.name
  description = "The name of the created custom VPC"
}

output "subnet_name" {
  value       = google_compute_subnetwork.secure_subnet.name
  description = "The name of the created secure subnet"
}