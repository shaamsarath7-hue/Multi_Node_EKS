# Session Notes

## Session 1 - <today's date>
- Launched controller EC2 (t3.small, Ubuntu 22.04) in KodeKloud AWS playground
- Installed terraform, kubectl, helm, aws-cli from scratch
- Configured aws cli with playground IAM credentials
- Created repo skeleton

## Session 2 - $(date +%Y-%m-%d)
- Terraform: VPC (2 public+2 private subnets, IGW, NAT), EKS control plane, self-managed system+workload node groups, OIDC/IRSA
- Playground note: managed node groups are blocked (explicit IAM deny) - using self-managed ASGs + aws-auth ConfigMap instead
- Verified: kubectl get nodes shows 2 nodes joined

## Session - $(date +%Y-%m-%d) - Stage 5
- Enabled VPC CNI network policy enforcement (enableNetworkPolicy=true) via
  aws_eks_addon - confirmed aws-eks-nodeagent running on daemonset aws-node.
- RBAC: workloads namespace, workload-sa ServiceAccount, least-privilege
  pod-reader Role (get/list/watch pods+logs only).
- NetworkPolicy: default-deny-all in workloads ns, explicit allows for DNS,
  ingress-nginx, and monitoring scrape traffic.
- ingress-nginx installed as ClusterIP (playground blocks external ELB/NLB
  for EKS) - reachable via kubectl port-forward, confirmed 404 on root path.
