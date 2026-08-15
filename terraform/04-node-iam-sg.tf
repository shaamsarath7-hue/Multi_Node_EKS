# Playground requires this EXACT role name for worker nodes
resource "aws_iam_role" "node_role" {
  name = "AmazonEKSNodeRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Handy for troubleshooting nodes via SSM Session Manager instead of SSH
resource "aws_iam_role_policy_attachment" "node_ssm_policy" {
  role       = aws_iam_role.node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node_profile" {
  name = "AmazonEKSNodeRole-instance-profile"
  role = aws_iam_role.node_role.name
}

resource "aws_security_group" "node_sg" {
  name        = "${var.cluster_name}-node-sg"
  description = "Security group for EKS self-managed worker nodes"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name                                        = "${var.cluster_name}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

resource "aws_security_group_rule" "node_self_ingress" {
  type                     = "ingress"
  from_port                = 0
  to_port                  = 65535
  protocol                 = "-1"
  security_group_id        = aws_security_group.node_sg.id
  source_security_group_id = aws_security_group.node_sg.id
  description              = "Allow nodes to talk to each other"
}

resource "aws_security_group_rule" "node_from_cluster_kubelet" {
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.node_sg.id
  source_security_group_id = aws_security_group.cluster_sg.id
  description              = "Allow control plane to reach kubelet"
}

resource "aws_security_group_rule" "node_from_cluster_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.node_sg.id
  source_security_group_id = aws_security_group.cluster_sg.id
  description              = "Allow control plane to reach extension API servers running on nodes"
}

resource "aws_security_group_rule" "node_egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.node_sg.id
}

resource "aws_security_group_rule" "cluster_from_node_https" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster_sg.id
  source_security_group_id = aws_security_group.node_sg.id
  description              = "Allow nodes to reach the control plane API"
}

# Latest EKS-optimized Amazon Linux 2 AMI for our chosen Kubernetes version
data "aws_ssm_parameter" "eks_ami" {
  name = "/aws/service/eks/optimized-ami/${var.kubernetes_version}/amazon-linux-2/recommended/image_id"
}
