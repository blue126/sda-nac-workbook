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

module "catalyst_center" {
  source  = "netascode/nac-catalystcenter/catalystcenter"
  version = "0.6.0"

  yaml_directories = ["data/"]
}
