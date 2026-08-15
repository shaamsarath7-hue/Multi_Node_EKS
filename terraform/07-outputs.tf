output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  value     = aws_eks_cluster.main.certificate_authority[0].data
  sensitive = true
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "node_role_arn" {
  description = "Paste this into aws-auth-cm.yaml's rolearn field"
  value       = aws_iam_role.node_role.arn
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "cluster_autoscaler_role_arn" {
  description = "Annotate the cluster-autoscaler ServiceAccount with this ARN in Stage 3"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "system_asg_name" {
  value = aws_autoscaling_group.system.name
}

output "workload_asg_name" {
  value = aws_autoscaling_group.workload.name
}
