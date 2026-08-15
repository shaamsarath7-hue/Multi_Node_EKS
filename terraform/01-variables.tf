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
