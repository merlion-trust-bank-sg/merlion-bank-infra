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

output "databases" {
  value = module.rds.databases
}

# Read by the Argo CD bootstrap step and passed to the add-ons as cluster annotations
output "vpc_id" {
  value = module.network.vpc_id
}
