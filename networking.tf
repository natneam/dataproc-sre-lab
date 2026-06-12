resource "google_compute_network" "custom_vpc" {
  name                    = var.custom_vpc
  auto_create_subnetworks = false # Disables default subnet generation

  depends_on = [google_project_service.enabled_apis]
}

resource "google_compute_subnetwork" "secure_subnet" {
  name                     = var.secure_subnet
  ip_cidr_range            = "10.10.0.0/24"
  region                   = var.region
  network                  = google_compute_network.custom_vpc.id
  private_ip_google_access = true # Enables PGA for VMs with only internal IPs
}

resource "google_compute_router" "router" {
  name    = var.router
  region  = var.region
  network = google_compute_network.custom_vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = var.nat
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

resource "google_compute_firewall" "allow_internal" {
  name    = var.allow_internal
  network = google_compute_network.custom_vpc.id

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.10.0.0/24"]
}


# ====================================================================================
# This is a test section of the newtworkig firewall, will be commented out by default.
# ====================================================================================

# # This firewall rule blocks egress to Google APIs from VMs running as the Dataproc Worker Service Account
# resource "google_compute_firewall" "block_google_apis_egress" {
#   name      = "block-egress-to-google-apis"
#   network   = google_compute_network.custom_vpc.id
#   direction = "EGRESS"
#   priority  = 1000

#   deny {
#     protocol = "tcp"
#     ports    = ["443"]
#   }

#   destination_ranges = ["0.0.0.0/0"]

#   # Only block egress for VMs running as the Dataproc Worker Service Account
#   target_service_accounts = [google_service_account.dataproc_sa.email]
# }