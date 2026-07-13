# --------------------------------------------------------------------------
# Data resource blocks
# --------------------------------------------------------------------------
data "google_project" "project" {}

# --------------------------------------------------------------------------
# VPC Configuration
# --------------------------------------------------------------------------
module "producer_vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "producer-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  subnets = [
    {
      name                     = "producer-subnet"
      region                   = var.producer_region
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "10.1.0.0/24"
    },
    {
      name                     = "nat-subnet"
      region                   = var.producer_region
      purpose                  = "PRIVATE_NAT"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "192.168.1.0/24"
    }
  ]
  firewall_data = [
    {
      name          = "producer-vpc-firewall-http"
      target_tags   = ["producer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["80"]
        }
      ]
    },
    {
      name          = "producer-vpc-firewall-https"
      target_tags   = ["producer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["443"]
        }
      ]
    },
    {
      name          = "producer-vpc-firewall-ssh"
      target_tags   = ["producer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["22"]
        }
      ]
    }
  ]
}

module "consumer_vpc" {
  source                          = "./modules/vpc"
  vpc_name                        = "consumer-vpc"
  delete_default_routes_on_create = false
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  subnets = [
    {
      name                     = "consumer-subnet"
      region                   = var.consumer_region
      purpose                  = "PRIVATE"
      role                     = "ACTIVE"
      private_ip_google_access = true
      ip_cidr_range            = "10.1.0.0/24"
    }
  ]
  firewall_data = [
    {
      name          = "consumer-vpc-firewall-http"
      target_tags   = ["consumer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["80"]
        }
      ]
    },
    {
      name          = "consumer-vpc-firewall-https"
      target_tags   = ["consumer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["443"]
        }
      ]
    },
    {
      name          = "consumer-vpc-firewall-ssh"
      target_tags   = ["consumer-instance"]
      source_ranges = ["0.0.0.0/0"]
      allow_list = [
        {
          protocol = "tcp"
          ports    = ["22"]
        }
      ]
    }
  ]
}

# --------------------------------------------------------------------------
# Network Connectivity Center (NCC) Configuration
# --------------------------------------------------------------------------
module "hub_spoke" {
  source          = "./modules/hub-spoke"
  hub_name        = "hub"
  hub_description = "A sample hub"
  spokes = [
    {
      spoke_name             = "spoke1"
      location               = "global"
      linked_vpc_network_uri = module.producer_vpc.self_link
    },
    {
      spoke_name             = "spoke2"
      location               = "global"
      linked_vpc_network_uri = module.consumer_vpc.self_link
    }
  ]
}

# --------------------------------------------------------------------------
# Cloud Router and Private NAT Gateway
# --------------------------------------------------------------------------
resource "google_compute_router" "router" {
  name    = "router"
  region  = var.producer_region
  network = module.producer_vpc.self_link
}

resource "google_compute_router_nat" "router_nat" {
  name                                = "router-nat"
  router                              = google_compute_router.router.name
  region                              = google_compute_router.router.region
  source_subnetwork_ip_ranges_to_nat  = "LIST_OF_SUBNETWORKS"
  enable_dynamic_port_allocation      = false
  enable_endpoint_independent_mapping = false
  min_ports_per_vm                    = 32
  type                                = "PRIVATE"     
  subnetwork {
    name                    = module.producer_vpc.subnets[0].id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
  rules {
    rule_number = 100
    description = "rule for private nat"
    match       = "nexthop.hub == \"//networkconnectivity.googleapis.com/projects/${data.google_project.project.project_id}/locations/global/hubs/${module.hub_spoke.name}\""
    action {
      source_nat_active_ranges = [
        module.producer_vpc.subnets[0].self_link
      ]
    }
  }
}

# --------------------------------------------------------------------------
# Compute Instances
# --------------------------------------------------------------------------

# Producer Instance
module "producer_instance" {
  source                    = "./modules/compute"
  name                      = "producer-instance"
  machine_type              = "e2-micro"
  zone                      = "${var.producer_region}-a"
  metadata_startup_script   = "sudo apt-get update; sudo apt-get install nginx -y"
  deletion_protection       = false
  allow_stopping_for_update = true
  image                     = "ubuntu-os-cloud/ubuntu-2004-focal-v20220712"
  network_interfaces = [
    {
      network        = "${module.producer_vpc.vpc_id}"
      subnetwork     = "${module.producer_vpc.subnets[0].id}"
      access_configs = []
    }
  ]
  tags = ["producer-instance"]
}

# Consumer Instance
module "consumer_instance" {
  source                    = "./modules/compute"
  name                      = "consumer-instance"
  machine_type              = "e2-micro"
  zone                      = "${var.consumer_region}-a"
  metadata_startup_script   = "sudo apt-get update; sudo apt-get install nginx -y"
  deletion_protection       = false
  allow_stopping_for_update = true
  image                     = "ubuntu-os-cloud/ubuntu-2004-focal-v20220712"
  network_interfaces = [
    {
      network        = "${module.consumer_vpc.vpc_id}"
      subnetwork     = "${module.consumer_vpc.subnets[0].id}"
      access_configs = []
    }
  ]
  tags = ["consumer-instance"]
}