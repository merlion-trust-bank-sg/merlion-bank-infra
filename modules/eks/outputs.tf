output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "EKS-managed security group attached to the control plane and the managed nodes"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  value = aws_iam_role.this["node"].arn
}

output "pod_identity_trust_policy" {
  description = "Trust policy JSON for Pod Identity roles added later (Loki, Grafana, External Secrets)"
  value       = data.aws_iam_policy_document.trust["ebs_csi"].json
}
