# Task 8 – integrate Catalyst Center with ISE.
#
# Written against the provider directly instead of the module's
# system_settings.authentication_and_policy_servers.ise: module 0.6.0 builds the
# ISE username/password/FQDN (cc_system_settings.tf, local.cisco_ise_dtos) but never
# passes them to the resource, so Catalyst Center could not establish trust with ISE.
#
# Secrets use write-only arguments (*_wo): they are sent to Catalyst Center but never
# stored in Terraform state. Bump the *_version number to push a changed secret.

variable "ise_ip" {
  type    = string
  default = "192.168.1.221"
}

variable "ise_fqdn" {
  type    = string
  default = null
}

variable "ise_username" {
  type    = string
  default = null
}

variable "ise_password" {
  type      = string
  default   = null
  sensitive = true
  ephemeral = true
}

variable "ise_shared_secret" {
  type      = string
  default   = null
  sensitive = true
  ephemeral = true
}

variable "ise_secrets_version" {
  description = "Increment after changing ise_password or ise_shared_secret."
  type        = number
  default     = 1
}

resource "catalystcenter_authentication_policy_server" "ise" {
  count = var.ise_fqdn == null ? 0 : 1

  ip_address          = var.ise_ip
  is_ise_enabled      = true
  protocol            = "RADIUS"
  authentication_port = 1812
  accounting_port     = 1813
  retries             = 3
  timeout_seconds     = 4
  role                = "primary"
  pxgrid_enabled      = true

  shared_secret_wo         = var.ise_shared_secret
  shared_secret_wo_version = var.ise_secrets_version

  cisco_ise_dtos = [{
    ip_address          = var.ise_ip
    fqdn                = var.ise_fqdn
    subscriber_name     = "catalystcenter"
    user_name           = var.ise_username
    password_wo         = var.ise_password
    password_wo_version = var.ise_secrets_version
  }]
}

# Accepts the ISE certificate and completes the pxGrid handshake.
resource "catalystcenter_integrate_ise" "ise" {
  count = var.ise_fqdn == null ? 0 : 1

  ise_instance_id = catalystcenter_authentication_policy_server.ise[0].id
}
