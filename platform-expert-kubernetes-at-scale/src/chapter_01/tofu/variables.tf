# variables.tf
# Reads shared constants from the single source of truth.
# DO NOT re-declare CIDRs, IPs, or domains here.

locals {
  constants = yamldecode(file("${path.module}/../constants.yaml"))

  # Convenience aliases — read-only references to constants
  cluster  = local.constants.cluster
  dns      = local.constants.dns
  nodes    = local.constants.nodes
  versions = local.constants.versions
}

# Stack-specific variables (not shared constants)
variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the public domain (if applicable)"
  type        = string
  default     = ""
}
