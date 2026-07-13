# GCP Inter-VPC Connectivity with Network Connectivity Center (NCC) & Private NAT

This Terraform configuration provisions a **producer/consumer VPC topology** connected through **Network Connectivity Center (NCC)**, with a **Private NAT gateway** on the producer VPC that translates traffic for the NCC hub's connected spokes. It also provisions demo Compute Engine instances in each VPC for connectivity testing.

## Architecture

```
                         ┌─────────────────────────────┐
                         │   Network Connectivity Ctr  │
                         │           (hub)              │
                         │  ┌────────┐   ┌────────┐    │
                         │  │ spoke1 │   │ spoke2 │    │
                         │  └───┬────┘   └────┬───┘    │
                         └──────┼─────────────┼─────────┘
                                │             │
              ┌─────────────────▼───┐   ┌─────▼──────────────┐
              │   producer-vpc       │   │   consumer-vpc      │
              │                       │   │                     │
              │  producer-subnet      │   │  consumer-subnet    │
              │  (10.1.0.0/24)        │   │  (10.1.0.0/24)      │
              │                       │   │                     │
              │  nat-subnet           │   │  [consumer-instance]│
              │  (192.168.1.0/24,     │   │                     │
              │   purpose=PRIVATE_NAT)│   │                     │
              │                       │   │                     │
              │  [producer-instance]  │   │                     │
              │                       │   │                     │
              │  ┌─────────────────┐  │   │                     │
              │  │  Cloud Router    │  │   │                     │
              │  │  + Private NAT   │  │   │                     │
              │  │  (rule matches   │  │   │                     │
              │  │  nexthop.hub)    │  │   │                     │
              │  └─────────────────┘  │   │                     │
              └───────────────────────┘   └─────────────────────┘
```

**What this builds:**

- Two custom-mode VPCs (`producer-vpc`, `consumer-vpc`), each with its own subnet(s) and baseline firewall rules (HTTP/HTTPS/SSH).
- A dedicated `PRIVATE_NAT`-purpose subnet (`nat-subnet`) in the producer VPC to serve as the Private NAT source range.
- An NCC hub with both VPCs attached as spokes, enabling inter-VPC routing without VPC Peering.
- A Cloud Router + Private NAT gateway (`type = PRIVATE`) in the producer VPC, with a custom NAT rule that matches traffic destined for the NCC hub (`nexthop.hub == ...`) and translates it using addresses from `nat-subnet`.
- A demo Compute Engine instance in each VPC (`producer-instance`, `consumer-instance`) with Nginx installed via startup script, for validating end-to-end connectivity.

## Repository Structure

```
.
├── main.tf                  # Root module (this configuration)
├── variables.tf              # Root input variables
├── outputs.tf                # Root outputs (recommended, see below)
├── versions.tf               # Provider & Terraform version constraints
├── terraform.tfvars.example  # Example variable values
└── modules/
    ├── vpc/                  # VPC, subnets, firewall rules
    ├── hub-spoke/             # NCC hub + spokes
    └── compute/               # Compute Engine instance
```

> This README assumes the module source paths referenced in `main.tf` (`./modules/vpc`, `./modules/hub-spoke`, `./modules/compute`) exist in your repository with the interfaces described below. Adjust paths if your layout differs.

## Prerequisites

| Requirement | Notes |
|---|---|
| Terraform | `>= 1.5` (uses `import` blocks / current resource schema conventions) |
| Google provider | `hashicorp/google >= 5.30` (Private NAT `rules`/`action` block and `PRIVATE_NAT` subnet purpose support) |
| GCP Project | With billing enabled |
| IAM permissions | `roles/compute.networkAdmin`, `roles/networkconnectivity.hubAdmin` (or `Owner`/`Editor` for a sandbox) on the target project |
| Enabled APIs | `compute.googleapis.com`, `networkconnectivity.googleapis.com` |

Enable the required APIs before applying:

```bash
gcloud services enable compute.googleapis.com networkconnectivity.googleapis.com \
  --project="$PROJECT_ID"
```

## Providers

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30, < 7.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.producer_region
}
```

## Input Variables

| Name | Description | Type | Required | Example |
|---|---|---|---|---|
| `project_id` | GCP project ID to deploy into | `string` | yes | `"my-ncc-demo-project"` |
| `producer_region` | Region for the producer VPC, its subnets, and the producer Compute instance | `string` | yes | `"us-central1"` |
| `consumer_region` | Region for the consumer VPC and its Compute instance | `string` | yes | `"us-east1"` |

> **Note:** `producer_region` is also passed as the `zone` argument to the `compute` module in this configuration. Confirm whether your `./modules/compute` module expects a full zone (e.g. `us-central1-a`) or a region — if it expects a zone, update the root module to pass an explicit zone variable rather than reusing the region value directly.

Create a `terraform.tfvars`:

```hcl
project_id      = "my-ncc-demo-project"
producer_region = "us-central1"
consumer_region = "us-east1"
```

## Usage

```bash
# 1. Authenticate
gcloud auth application-default login

# 2. Initialize
terraform init

# 3. Review the plan
terraform plan -var-file="terraform.tfvars"

# 4. Apply
terraform apply -var-file="terraform.tfvars"
```

### Validating connectivity

Once applied, SSH into either instance via [IAP tunneling](https://cloud.google.com/iap/docs/using-tcp-forwarding) (no external IPs are configured — `access_configs = []`):

```bash
gcloud compute ssh producer-instance \
  --zone="${PRODUCER_REGION}-a" \
  --tunnel-through-iap \
  --project="$PROJECT_ID"
```

From the producer instance, curl the consumer instance's internal IP to confirm the NCC hub is routing traffic between the two non-peered VPCs, and inspect NAT translation logs (if enabled) to confirm Private NAT is applying to hub-bound traffic.

### Destroying

```bash
terraform destroy -var-file="terraform.tfvars"
```

## Design Notes & Gotchas

- **Overlapping subnet CIDRs:** `producer-subnet` and `consumer-subnet` are both currently `10.1.0.0/24`. Since both VPCs are attached to the same NCC hub as spokes, **overlapping ranges will prevent proper route propagation between them** unless you are intentionally relying on Private NAT to translate around the overlap. If direct (non-NAT'd) routing between the two subnets is required, assign non-overlapping CIDRs.
- **Private NAT subnet purpose:** `nat-subnet` must retain `purpose = "PRIVATE_NAT"`. Terraform/GCP will reject NAT rules referencing a subnet without this purpose.
- **NAT rule vs. default subnetwork block:** This configuration combines a top-level `subnetwork` block (for `producer-subnet`) *and* a `rules` block matching NCC hub traffic. Confirm this dual configuration reflects your intended behavior — typically, Private-NAT-for-NCC-hub traffic is driven primarily through the `rules[].action.source_nat_active_ranges` matching `nexthop.hub`, while the top-level `subnetwork` block governs which subnet's VMs are eligible for NAT at all. Review the [Private NAT for NCC spokes documentation](https://cloud.google.com/nat/docs/about-private-nat-for-ncc) to confirm alignment with your traffic requirements.
- **Firewall rules:** All three firewall rules per VPC allow `0.0.0.0/0` as the source range for HTTP/HTTPS/SSH. This is convenient for demos but **should be tightened** before any non-ephemeral use (see Security section below).
- **Image reference:** `ubuntu-os-cloud/ubuntu-2004-focal-v20220712` pins to a specific (now dated) Ubuntu 20.04 image build. Consider using the `ubuntu-os-cloud/ubuntu-2004-lts` family alias, or upgrading to a current LTS release, so instances stay patched — see Security section.
- **`google_project` data source:** Used only to build the NCC hub URL in the NAT rule's `match` CEL expression (`data.google_project.project.project_id`). Ensure the runtime service account has `resourcemanager.projects.get` on the target project.

## Security Recommendations

This configuration is written for **demonstration/POC purposes**. Before using in production:

1. **Restrict firewall source ranges.** Replace `0.0.0.0/0` with known CIDR ranges (VPN ranges, IAP range `35.235.240.0/20` for SSH, corporate egress IPs) rather than the open internet.
2. **Remove or scope SSH exposure.** Prefer [IAP-based SSH](https://cloud.google.com/iap/docs/using-tcp-forwarding) exclusively (source range `35.235.240.0/20`) instead of `0.0.0.0/0:22`.
3. **Enable Shielded VM options and OS Login** on the `compute` module (`enable_secure_boot`, `enable_vtpm`, `enable_integrity_monitoring`, `enable-oslogin` metadata) for hardened instance security.
4. **Enable NAT + VPC Flow Logs** for auditability:
   ```hcl
   log_config {
     enable = true
     filter = "ERRORS_ONLY"
   }
   ```
5. **Pin provider and module versions** explicitly (see `versions.tf`) to avoid unreviewed upstream changes being pulled in on `terraform init`.
6. **Use a remote, encrypted backend** (GCS with customer-managed encryption key and object versioning) instead of local state, and enable state locking.
7. **Least-privilege service account** for Terraform execution — avoid `Owner`/`Editor`; scope to the specific roles listed in Prerequisites.

## Suggested Backend Configuration

```hcl
terraform {
  backend "gcs" {
    bucket = "my-org-terraform-state"
    prefix = "ncc-private-nat-demo"
  }
}
```

## Outputs (recommended additions)

Add an `outputs.tf` to surface useful values for verification and downstream automation:

```hcl
output "producer_vpc_self_link" {
  description = "Self link of the producer VPC"
  value       = module.producer_vpc.self_link
}

output "consumer_vpc_self_link" {
  description = "Self link of the consumer VPC"
  value       = module.consumer_vpc.self_link
}

output "ncc_hub_id" {
  description = "ID of the Network Connectivity Center hub"
  value       = module.hub_spoke.name
}

output "router_nat_name" {
  description = "Name of the Private NAT gateway"
  value       = google_compute_router_nat.router_nat.name
}

output "producer_instance_internal_ip" {
  description = "Internal IP of the producer instance"
  value       = module.producer_instance.internal_ip
}

output "consumer_instance_internal_ip" {
  description = "Internal IP of the consumer instance"
  value       = module.consumer_instance.internal_ip
}
```

> Adjust attribute names (`internal_ip`, etc.) to match whatever your `./modules/compute` module actually exposes.

## Troubleshooting

| Symptom | Likely Cause |
|---|---|
| `Error: Attribute network_connectivity_center_hub not found` | That attribute doesn't exist on `google_compute_router_nat`; use the `rules { match = "nexthop.hub == ..." }` pattern shown in this config instead. |
| NAT rule `match` fails to apply / traffic not translated | Confirm the hub URL format exactly matches `//networkconnectivity.googleapis.com/projects/PROJECT_ID/locations/global/hubs/HUB_NAME`, and that both VPCs are actually attached as **active** spokes (`gcloud network-connectivity spokes list`). |
| Consumer/producer instances can't reach each other | Check for overlapping subnet CIDRs across spokes (see Design Notes), and confirm firewall rules permit the relevant traffic between the internal ranges. |
| `Error 400: Invalid value for field 'resource.subnetworks'` on NAT | Referenced subnetwork does not have `purpose = PRIVATE_NAT`. |

## References

- [Private NAT for Network Connectivity Center spokes](https://cloud.google.com/nat/docs/about-private-nat-for-ncc)
- [Network Connectivity Center overview](https://cloud.google.com/network-connectivity/docs/network-connectivity-center)
- [`google_compute_router_nat` resource docs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_router_nat)
- [`google_network_connectivity_hub` resource docs](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/network_connectivity_hub)

## License

Add your organization's license here (e.g. Apache 2.0, MIT).
