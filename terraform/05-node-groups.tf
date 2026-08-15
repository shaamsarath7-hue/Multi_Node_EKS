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
}
