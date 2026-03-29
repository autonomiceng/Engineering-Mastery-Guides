# providers.tf
# Example: Cloudflare provider for public DNS records.
# For private home.arpa DNS, use Synology DNS Server (manual/runbook).

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  # Set via environment: CLOUDFLARE_API_TOKEN
}
