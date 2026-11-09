output "environment" {
  value = local.environment
}

output "name_prefix" {
  value = local.name
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
