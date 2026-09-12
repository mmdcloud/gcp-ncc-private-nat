variable "project_id" {
  description = "GCP project ID where all resources will be created."
  type        = string
}

variable "producer_region" {
  description = "Default region (used only if needed elsewhere)"
  type        = string
  default     = "asia-south1"
}

variable "consumer_region" {
  description = "Default region (used only if needed elsewhere)"
  type        = string
  default     = "asia-south2"
}

variable "image_family" {
  description = "Source image family for compute instances."
  type        = string
  default     = "ubuntu-2404-lts-amd64"
}

variable "image_project" {
  description = "Project that owns the source image family."
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "instance_boot_disk_size_gb" {
  description = "Boot disk size (GB) for the compute instances."
  type        = number
  default     = 10
}

variable "instance_boot_disk_type" {
  description = "Boot disk type for the compute instances."
  type        = string
  default     = "pd-ssd"
}

variable "instance_labels" {
  description = "Resource labels applied to the instances and its boot disk."
  type        = map(string)
  default = {
    environment = "production"
    team        = "platform-eng"
    cost_center = "cc-1042"
  }
}