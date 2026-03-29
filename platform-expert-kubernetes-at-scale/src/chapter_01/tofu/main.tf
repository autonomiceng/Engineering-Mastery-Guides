# main.tf
# Example: Create a public DNS record for the Kubernetes API endpoint.
#
# NOTE: This is for demonstration of the shared-constants pattern.
# In the reference architecture, private DNS (home.arpa) is managed
# on Synology DNS Server via runbook, NOT via OpenTofu.
#
# Use this pattern only when:
#   - You have a public domain on Cloudflare (or similar provider)
#   - You want API access from outside the home network
#   - The provider has a stable API worth managing in state

resource "cloudflare_record" "k8s_api" {
  count = var.cloudflare_zone_id != "" ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = "k8s-api"
  content = local.cluster.api_vip
  type    = "A"
  ttl     = 300
  proxied = false

  comment = "Kubernetes API VIP - managed by OpenTofu"
}

# Demonstrate reading constants for validation
resource "null_resource" "constants_validation" {
  triggers = {
    api_vip     = local.cluster.api_vip
    api_dns     = local.cluster.api_dns
    pod_cidr    = local.cluster.pod_cidr
    service_cidr = local.cluster.service_cidr
    rke2_version = local.versions.rke2
  }
}
