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
