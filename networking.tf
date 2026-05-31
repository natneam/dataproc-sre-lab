resource "google_compute_network" "custom_vpc" {
  name                    = "my-custom-vpc"
  auto_create_subnetworks = false # Disables default subnet generation
}

resource "google_compute_subnetwork" "secure_subnet" {
  name                     = "my-secure-subnet"
  ip_cidr_range            = "10.10.0.0/24"
  region                   = var.region
  network                  = google_compute_network.custom_vpc.id
  private_ip_google_access = true # Enables PGA for VMs with only internal IPs
}

resource "google_compute_router" "router" {
  name    = "my-cloud-router"
  region  = var.region
  network = google_compute_network.custom_vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "my-cloud-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY" # Dynamically scale public IPs
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"

  # Apply NAT strictly to our secure subnet to limit outbound scope
  subnetwork {
    name                    = google_compute_subnetwork.secure_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}