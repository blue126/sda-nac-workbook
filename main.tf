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

# Build stage (see WORKBOOK). Stage N loads the YAML files of stages 1..N, so a fresh
# clone can be built step by step: terraform plan -var stage=1, then 2, then 3.
# Never lower it on an existing build: the missing stages would be planned for destroy.
variable "stage" {
  type    = number
  default = 3
  validation {
    condition     = contains([1, 2, 3], var.stage)
    error_message = "stage must be 1, 2 or 3."
  }
}

locals {
  stage_files = [
    "data/01_sites_pools.nac.yaml", # Stage 1: Tasks 8-10
    "data/02_aaa_devices.nac.yaml", # Stage 2: Tasks 11-12
    "data/03_fabric.nac.yaml",      # Stage 3: Tasks 13-17
  ]
}

# Task 10: ISE credentials, kept in terraform.tfvars like the CatC ones. They are merged
# into the YAML model (data/01 holds the rest of the ISE settings). The module passes
# them to write-only arguments, so they are not stored in state; they do end up in
# saved .tfplan files (gitignored, delete after apply). Not marked sensitive because a
# sensitive value would make the whole merged model sensitive and break the module's
# for_each loops; the module wraps the password and secret in sensitive() itself.
variable "ise_username" {
  type = string
}

variable "ise_password" {
  type = string
}

variable "ise_shared_secret" {
  type = string
}

module "catalyst_center" {
  source  = "netascode/nac-catalystcenter/catalystcenter"
  version = "0.6.0"

  yaml_files = slice(local.stage_files, 0, var.stage)
  model = {
    catalyst_center = {
      system_settings = {
        authentication_and_policy_servers = {
          ise = {
            username      = var.ise_username
            password      = var.ise_password
            shared_secret = var.ise_shared_secret
          }
        }
      }
    }
  }
}

