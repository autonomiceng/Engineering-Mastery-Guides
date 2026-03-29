# main.tf
# Optional: Configure GitHub webhook for ArgoCD.
# This triggers ArgoCD to check for changes immediately on push,
# rather than waiting for the 3-minute reconciliation interval.
#
# Only useful if:
#   - ArgoCD is reachable from GitHub (public endpoint or GitHub Actions runner)
#   - You want sub-minute deployment latency
#
# For private homelab clusters, the default polling is sufficient.

locals {
  constants = yamldecode(file("${path.module}/../../chapter_01/constants.yaml"))
}

# Example: GitHub webhook for ArgoCD (requires public endpoint)
# Uncomment and configure if ArgoCD has a publicly reachable URL.
#
# resource "github_repository_webhook" "argocd" {
#   repository = "home-lab"
#
#   configuration {
#     url          = "https://argocd.${local.constants.dns.lab_domain}/api/webhook"
#     content_type = "json"
#     insecure_ssl = false
#   }
#
#   events = ["push"]
#   active = true
# }

# Verify constants are accessible
output "argocd_dns_name" {
  description = "ArgoCD DNS name from shared constants"
  value       = "argocd.${local.constants.dns.lab_domain}"
}

output "rancher_dns_name" {
  description = "Rancher DNS name from shared constants"
  value       = "rancher.${local.constants.dns.lab_domain}"
}
