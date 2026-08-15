# Enables Kubernetes NetworkPolicy enforcement. Without this, the VPC CNI
# allows all pod-to-pod traffic regardless of any NetworkPolicy we write -
# this addon deploys the eBPF-based network-policy-agent onto every node.
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
