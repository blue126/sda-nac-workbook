# SD-Access fabric for the PNETLab lab, managed with Network as Code.
# Credentials: copy terraform.tfvars.example to terraform.tfvars (gitignored) and fill it in.
# If the variables are left unset, the provider falls back to CC_USERNAME / CC_PASSWORD.
terraform {
  required_version = ">= 1.15.0"
  required_providers {
    catalystcenter = {
      source  = "CiscoDevNet/catalystcenter"
      version = "~> 0.6.6"
    }
    ise = {
      source  = "CiscoDevNet/ise"
      version = "~> 0.5.2"
    }
  }
}

variable "catalystcenter_url" {
  type    = string
  default = "https://192.168.1.133"
}

variable "catalystcenter_username" {
  type    = string
  default = null
}

variable "catalystcenter_password" {
  type      = string
  default   = null
  sensitive = true
}

provider "catalystcenter" {
  url         = var.catalystcenter_url
  username    = var.catalystcenter_username
  password    = var.catalystcenter_password
  max_timeout = 600
}

# ISE for Stage 4 (nac-ise). Credentials: ISE_USERNAME / ISE_PASSWORD environment variables.
variable "ise_url" {
  type    = string
  default = "https://192.168.1.221"
}

provider "ise" {
  url = var.ise_url
}

# Build stage (see WORKBOOK). Stage N loads the YAML files of stages 0..N, so a fresh
# clone can be built step by step: terraform plan -var stage=0, then 1, 2, 3, 4.
# Never lower it on an existing build: the missing stages would be planned for destroy.
variable "stage" {
  type    = number
  default = 4
  validation {
    condition     = contains([0, 1, 2, 3, 4], var.stage)
    error_message = "stage must be 0, 1, 2, 3 or 4."
  }
}

locals {
  # Files per stage. nac-catalystcenter, nac-iosxe and nac-ise each need their own files
  # (a YAML file may hold only one of catalyst_center / iosxe / ise).
  stages = [
    { catc = [], iosxe = ["data/00_fusion.nac.yaml"], ise = [] },                                  # Stage 0
    { catc = ["data/01_sites_pools.nac.yaml"], iosxe = [], ise = [] },                             # Stage 1
    { catc = ["data/02_aaa_devices.nac.yaml"], iosxe = [], ise = [] },                             # Stage 2
    { catc = ["data/03_fabric.nac.yaml"], iosxe = ["data/03_fusion_handoff.nac.yaml"], ise = [] }, # Stage 3
    { catc = [], iosxe = [], ise = ["data/04_ise_policy.nac.yaml"] },                              # Stage 4
  ]
  catc_files  = flatten([for s in slice(local.stages, 0, var.stage + 1) : s.catc])
  iosxe_files = flatten([for s in slice(local.stages, 0, var.stage + 1) : s.iosxe])
  ise_files   = flatten([for s in slice(local.stages, 0, var.stage + 1) : s.ise])
}

module "catalyst_center" {
  source  = "netascode/nac-catalystcenter/catalystcenter"
  version = "0.6.0"

  yaml_files = local.catc_files
  # An empty catalyst_center model keeps the module valid at Stage 0, when it has no files.
  model = { catalyst_center = {} }
}

# FUSION-1 (Catalyst 8000V, outside Catalyst Center) over NETCONF: data/00 (Stage 0) and
# data/03_fusion_handoff (Stage 3).
# Credentials: IOSXE_USERNAME / IOSXE_PASSWORD environment variables only.
module "iosxe" {
  source  = "netascode/nac-iosxe/iosxe"
  version = "1.0.0"

  yaml_files  = local.iosxe_files
  save_config = true
}

# ISE policy (Stage 4): TrustSec matrix, identity groups, users, authorization, policy set.
# Vendored copy of netascode/nac-ise/ise 1.1.0 with one change (modules/nac-ise/VENDORED.md).
module "ise" {
  source = "./modules/nac-ise"

  yaml_files = local.ise_files
  # An empty ise model keeps the module valid before Stage 4.
  model = { ise = {} }
}
