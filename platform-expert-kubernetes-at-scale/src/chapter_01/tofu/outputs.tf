# outputs.tf
# Expose values for verification — NOT for consumption by Ansible.
# Ansible reads constants.yaml directly. Do not create a tofu output → Ansible pipeline.

output "api_endpoint" {
  description = "Kubernetes API endpoint (from shared constants)"
  value       = "https://${local.cluster.api_vip}:${local.cluster.api_port}"
}

output "api_dns_name" {
  description = "Kubernetes API DNS name (from shared constants)"
  value       = local.cluster.api_dns
}

output "rke2_version" {
  description = "Pinned RKE2 version (from shared constants)"
  value       = local.versions.rke2
}

output "node_ips" {
  description = "Node IP addresses (from shared constants)"
  value       = { for name, node in local.nodes : name => node.ip }
}
