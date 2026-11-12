terraform {
  required_version = ">= 1.11.0"

  required_providers {
    ise = {
      source  = "CiscoDevNet/ise"
      version = "~> 0.5.0"
    }
    utils = {
      source = "netascode/utils"
      # Vendored change: upstream pins exactly 2.0.0, which conflicts with nac-iosxe 1.0.0
      # (>= 2.0.2, < 3.0.0) in the same root module.
      version = ">= 2.0.0, < 3.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.10.0"
    }
  }
}
