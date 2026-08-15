#!/usr/bin/env bash
set -euo pipefail
cd ~/Multi_Node_EKS
rm -rf terraform/01-vpc terraform/02-eks-cluster terraform/03-node-groups terraform/04-irsa 2>/dev/null || true
mkdir -p terraform
cd terraform

cat > 00-provider.tf << 'FILEEOF'
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}
FILEEOF

cat > 01-variables.tf << 'FILEEOF'
variable "aws_region" {
  description = "AWS region. Playground supports us-east-1, us-east-2, us-west-2"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "multi-node-eks"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane"
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

# us-east-1e is blocked on the KodeKloud playground - never add it here
variable "azs" {
  description = "Availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.10.0/24", "10.0.11.0/24"]
}

# --- Node sizing, kept inside the playground's 6 vCPU / 12 GiB account-wide cap ---
# system: 1 x t3.medium (2 vCPU / 4 GiB)  = 2 vCPU / 4 GiB  (fixed size, no scaling)
# workload: 1-2 x t3.small (2 vCPU / 2 GiB each) = up to 4 vCPU / 4 GiB (autoscaled)
# worst case total = 6 vCPU / 8 GiB -> inside the 6 vCPU / 12 GiB cap

variable "system_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "workload_instance_type" {
  type    = string
  default = "t3.small"
}

variable "workload_min_size" {
  type    = number
  default = 1
}

variable "workload_max_size" {
  type    = number
  default = 2
}

variable "node_volume_size" {
  description = "Root EBS volume size in GB for worker nodes (playground caps this at 30GB, gp2 only)"
  type        = number
  default     = 20
}
FILEEOF

cat > 02-vpc.tf << 'FILEEOF'
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name                                        = "${var.cluster_name}-vpc"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.cluster_name}-igw"
  }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "${var.cluster_name}-public-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"
  }
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]

  tags = {
    Name                                        = "${var.cluster_name}-private-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"           = "1"
  }
}

# Single NAT gateway (not one per AZ) to keep this cheap and simple for a learning
# environment. Production-grade would use one per AZ for HA - noted in README.
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-nat-eip"
  }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name = "${var.cluster_name}-nat"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-public-rt"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "${var.cluster_name}-private-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
FILEEOF

cat > 03-eks-cluster.tf << 'FILEEOF'
# Playground requires this EXACT role name for the EKS cluster service role
resource "aws_iam_role" "eks_cluster_role" {
  name = "eksClusterRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_security_group" "cluster_sg" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

resource "aws_eks_cluster" "main" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids      = [aws_security_group.cluster_sg.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    # Tighten this to your controller EC2's IP/32 once you have it, e.g. ["1.2.3.4/32"]
    public_access_cidrs = ["0.0.0.0/0"]
  }

  # API_AND_CONFIG_MAP lets us keep using the traditional aws-auth ConfigMap
  # for our self-managed nodes below (playground-proven approach)
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]

  tags = {
    Name = var.cluster_name
  }
}
FILEEOF

cat > 04-node-iam-sg.tf << 'FILEEOF'
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
FILEEOF

cat > 05-node-groups.tf << 'FILEEOF'
# =====================================================================
# SYSTEM NODE GROUP - fixed size, hosts CoreDNS, metrics-server,
# cluster-autoscaler, kube-prometheus-stack. No autoscaling here.
# =====================================================================

resource "aws_launch_template" "system" {
  name_prefix   = "${var.cluster_name}-system-"
  image_id      = data.aws_ssm_parameter.eks_ami.value
  instance_type = var.system_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile.name
  }

  vpc_security_group_ids = [aws_security_group.node_sg.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_volume_size
      volume_type            = "gp2" # playground only allows gp2 for EBS
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 only
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -o xtrace
    /etc/eks/bootstrap.sh ${var.cluster_name} \
      --kubelet-extra-args '--node-labels=nodegroup-type=system,role=system'
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-system-node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "system" {
  name                = "${var.cluster_name}-system-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.system.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-system-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  depends_on = [aws_eks_cluster.main]

  lifecycle {
    create_before_destroy = true
  }
}

# =====================================================================
# WORKLOAD NODE GROUP - autoscaled by Cluster Autoscaler (min/max below),
# hosts the throwaway sample app + HPA demo in stage 6.
# Tagged so Cluster Autoscaler auto-discovers this ASG.
# =====================================================================

resource "aws_launch_template" "workload" {
  name_prefix   = "${var.cluster_name}-workload-"
  image_id      = data.aws_ssm_parameter.eks_ami.value
  instance_type = var.workload_instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.node_profile.name
  }

  vpc_security_group_ids = [aws_security_group.node_sg.id]

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.node_volume_size
      volume_type            = "gp2"
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -o xtrace
    /etc/eks/bootstrap.sh ${var.cluster_name} \
      --kubelet-extra-args '--node-labels=nodegroup-type=workload,role=workload'
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-workload-node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "workload" {
  name                = "${var.cluster_name}-workload-asg"
  desired_capacity    = var.workload_min_size
  min_size            = var.workload_min_size
  max_size            = var.workload_max_size
  vpc_zone_identifier = aws_subnet.private[*].id

  launch_template {
    id      = aws_launch_template.workload.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-workload-node"
    propagate_at_launch = true
  }

  tag {
    key                 = "kubernetes.io/cluster/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  # Cluster Autoscaler auto-discovery tags (used in Stage 3)
  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = true
  }

  depends_on = [aws_eks_cluster.main]

  lifecycle {
    create_before_destroy = true
  }
}
FILEEOF

cat > 06-irsa.tf << 'FILEEOF'
# =====================================================================
# IRSA (IAM Roles for Service Accounts) foundation
# =====================================================================

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# ---------------------------------------------------------------------
# IRSA role for Cluster Autoscaler - Stage 3's Helm install will
# annotate the cluster-autoscaler ServiceAccount with this role's ARN,
# so it can call autoscaling:SetDesiredCapacity etc. without static keys.
# ---------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.cluster_name}-cluster-autoscaler-irsa"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume.json
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:DescribeInstanceTypes"
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  role       = aws_iam_role.cluster_autoscaler.name
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
}
FILEEOF

cat > 07-outputs.tf << 'FILEEOF'
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
FILEEOF

cat > aws-auth-cm.yaml.tpl << 'FILEEOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: __NODE_ROLE_ARN__
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
FILEEOF

echo ">>> All Stage 2 Terraform files written to terraform/"
ls -la

