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

# Build stage (see WORKBOOK). Stage N loads the YAML files of stages 0..N, so a fresh
# clone can be built step by step: terraform plan -var stage=0, then 1, 2, 3.
# Never lower it on an existing build: the missing stages would be planned for destroy.
variable "stage" {
  type    = number
  default = 3
  validation {
    condition     = contains([0, 1, 2, 3], var.stage)
    error_message = "stage must be 0, 1, 2 or 3."
  }
}

locals {
  # Files per stage. nac-catalystcenter and nac-iosxe each need their own files
  # (a YAML file may hold only one of catalyst_center / iosxe).
  stages = [
    { catc = [], iosxe = ["data/00_fusion.nac.yaml"] },                                  # Stage 0
    { catc = ["data/01_sites_pools.nac.yaml"], iosxe = [] },                             # Stage 1
    { catc = ["data/02_aaa_devices.nac.yaml"], iosxe = [] },                             # Stage 2
    { catc = ["data/03_fabric.nac.yaml"], iosxe = ["data/03_fusion_handoff.nac.yaml"] }, # Stage 3
  ]
  catc_files  = flatten([for s in slice(local.stages, 0, var.stage + 1) : s.catc])
  iosxe_files = flatten([for s in slice(local.stages, 0, var.stage + 1) : s.iosxe])
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
