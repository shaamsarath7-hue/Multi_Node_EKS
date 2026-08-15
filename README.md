# Multi-Node EKS — Production-Grade Platform (KodeKloud AWS Playground Edition)

A pure-infrastructure, production-grade Amazon EKS platform built entirely
with Terraform: a real VPC, an EKS cluster with **two node groups** (system
vs. workload), **pod-level autoscaling** (HPA) and **node-level autoscaling**
(Cluster Autoscaler), a full **Prometheus + Grafana + Alertmanager**
observability stack, an **Ingress controller**, and **RBAC + NetworkPolicies**
for security. A trivial sample workload is deployed and load-tested purely to
*prove* the autoscaling and monitoring work under real traffic — the
workload itself is throwaway; the platform is the deliverable.

Built and rebuilt entirely inside the **KodeKloud AWS Cloud Playground**,
whose account resets every ~3 hours — so this repo, not AWS, is the source
of truth. See [Playground Constraints](#playground-constraints-discovered)
below for everything that had to be worked around.

---

## Architecture
<img width="3100" height="2387" alt="eks_architecture" src="https://github.com/user-attachments/assets/429b72f8-1a2b-4d0b-8229-1b105ffe9516" />


```
                                   Internet
                                       |
                          (No external LB - playground
                           blocks it; access via
                           kubectl port-forward)
                                       |
                          +------------------------+
                          |   ingress-nginx (SVC:   |
                          |   ClusterIP)            |
                          +------------------------+
                                       |
   VPC (10.0.0.0/16, 2 AZs: us-east-1a / us-east-1b)
   +-------------------------------------------------------------+
   |  Public subnets (10.0.0.0/24, 10.0.1.0/24)                  |
   |    - Internet Gateway                                       |
   |    - NAT Gateway (single, cost/simplicity tradeoff)          |
   |                                                               |
   |  Private subnets (10.0.10.0/24, 10.0.11.0/24)                |
   |                                                               |
   |    +------------------- EKS Control Plane -----------------+ |
   |    |         (AWS-managed, API_AND_CONFIG_MAP auth)         | |
   |    +----------------------------------------------------------+
   |                                                               |
   |    +-------------------+       +--------------------------+  |
   |    | SYSTEM node group | | WORKLOAD node group        |  |
   |    | 1x t3.medium       |       | 1-2x t3.small (HPA +     |  |
   |    | fixed size          |       | Cluster Autoscaler)      |  |
   |    |                     |       |                          |  |
   |    | - CoreDNS           |       | - php-apache (sample)    |  |
   |    | - metrics-server    |       | - load-generator         |  |
   |    | - cluster-autoscaler|       |   (throwaway, Stage 6)   |  |
   |    | - kube-prometheus-  |       |                          |  |
   |    |   stack             |       |                          |  |
   |    | - ingress-nginx     |       |                          |  |
   |    +-------------------+       +--------------------------+  |
   +-------------------------------------------------------------+

   Security:
   - RBAC: least-privilege ServiceAccount + Role (get/list/watch pods only)
   - NetworkPolicy: default-deny-all in `workloads` ns, explicit allows for
     DNS, ingress-nginx, Prometheus scrape, and intra-namespace traffic
   - Enforced by VPC CNI's aws-eks-nodeagent (enableNetworkPolicy=true)
```

**Node sizing rationale** — the playground caps the account at **6000
millicores (6 vCPU) and 12288 MiB (12 GiB) total**. Worst case (system node +
2 workload nodes at HPA max) is 6 vCPU / 8 GiB — comfortably inside the cap.

| Node group | Instance | Count | vCPU | RAM | Scaling |
|---|---|---|---|---|---|
| system | t3.medium | 1 (fixed) | 2 | 4 GiB | none |
| workload | t3.small | 1-2 | 2-4 | 2-4 GiB | Cluster Autoscaler, min=1/max=2 |

---

## Repo Structure

```
Multi_Node_EKS/
├── README.md                        <- you are here
├── terraform/                       <- single state, numbered read-order
│   ├── 00-provider.tf
│   ├── 01-variables.tf
│   ├── 02-vpc.tf
│   ├── 03-eks-cluster.tf            <- eksClusterRole + control plane
│   ├── 04-node-iam-sg.tf            <- AmazonEKSNodeRole + security groups
│   ├── 05-node-groups.tf            <- 2x self-managed ASG + launch templates
│   ├── 06-irsa.tf                   <- OIDC provider + Cluster Autoscaler role
│   ├── 07-outputs.tf
│   ├── 08-vpc-cni-addon.tf          <- enables NetworkPolicy enforcement
│   └── aws-auth-cm.yaml.tpl         <- lets self-managed nodes join
├── k8s/
│   ├── autoscaling/                 <- metrics-server + cluster-autoscaler values
│   ├── observability/               <- kube-prometheus-stack values + alert rules
│   ├── ingress/                     <- ingress-nginx values
│   ├── security/                    <- RBAC + NetworkPolicy manifests
│   └── sample-workload/             <- php-apache + HPA + Ingress + load-generator
├── scripts/
│   ├── bootstrap-toolkit.sh         <- installs terraform/kubectl/helm/aws-cli
│   └── deploy-all.sh                <- ONE-SHOT rebuild for a new session
└── docs/
    └── session-notes.md             <- running log of what was done each session
```

All Terraform lives in one flat directory / one state file rather than
per-component subfolders — the VPC, cluster, node groups, and IRSA all
reference each other directly (security group IDs, OIDC issuer URL, etc.),
so splitting state would just mean manually wiring outputs between states for
no real benefit at this scale.

---

## Quick Start — Rebuilding in a Brand New Playground Session

Because the KodeKloud AWS Playground **wipes the entire AWS account every
~3 hours**, every session starts from zero. The rule: **Git is the only
thing that persists. AWS is disposable and gets rebuilt from Git.**

### 1. Manual steps (need console access, can't be scripted)

1. Go to https://kodekloud.com/cloud-playgrounds/aws-free → **Start Lab** →
   open the AWS Console, note region is `us-east-1`.
2. Launch a controller EC2:
   - AMI: **Ubuntu Server 22.04 LTS**
   - Instance type: **t3.small**
   - Security group inbound: SSH (22) from `18.206.107.24/29` (the
     `us-east-1` EC2 Instance Connect service range — NOT "My IP", since
     Instance Connect traffic originates from AWS's own IP range)
   - CPU credit mode: **Standard** (Unlimited mode triggers session suspension)
3. Connect via **EC2 Instance Connect** (Console → select instance →
   Connect → EC2 Instance Connect tab → username `ubuntu`).

### 2. Bootstrap the toolkit

```bash
git clone <your-repo-url> ~/Multi_Node_EKS
cd ~/Multi_Node_EKS
bash scripts/bootstrap-toolkit.sh
```

### 3. Configure AWS credentials

Get access keys from the playground console: **IAM → Users → your
playground user → Security credentials → Create access key**, then:

```bash
aws configure
# Access Key ID / Secret Access Key: <paste>
# Region: us-east-1
# Output format: json

aws sts get-caller-identity   # confirm it resolves
```

### 4. Rebuild everything in one shot

```bash
cd ~/Multi_Node_EKS
bash scripts/deploy-all.sh
```

This runs, in order: Terraform (VPC → EKS → node groups → IRSA → VPC CNI) →
kubectl config → aws-auth ConfigMap → metrics-server + Cluster Autoscaler →
kube-prometheus-stack → RBAC + NetworkPolicies → ingress-nginx → sample
workload + HPA + Ingress. Takes **~20-25 minutes total**, mostly the EKS
control plane (~10-12 min).

It deliberately **stops short of the load generator** — see Stage 6 below —
so you can watch the scale-out live instead of it happening unattended.

### 5. Commit after every stage

```bash
git add .
git commit -m "Session N: <what changed>"
git push origin main
```

---

## Stage 6: Proving It Under Load

Once `deploy-all.sh` finishes, open **3-4 terminal tabs** to the controller
(via separate EC2 Instance Connect sessions) so you can watch everything
scale live:

**Tab A — pods/HPA:**
```bash
watch -n 2 'kubectl get hpa -n workloads; echo; kubectl get pods -n workloads -o wide'
```

**Tab B — nodes/ASG:**
```bash
watch -n 5 'kubectl get nodes -L nodegroup-type; echo; aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names multi-node-eks-workload-asg --query "AutoScalingGroups[0].[DesiredCapacity,MinSize,MaxSize]"'
```

**Tab C — Cluster Autoscaler decisions:**
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-cluster-autoscaler -f --tail=10 | grep -iE "scale|node|pending"
```

**Tab D — Grafana:**
```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

**Fire the load generator** (main terminal):
```bash
kubectl apply -f k8s/sample-workload/load-generator.yaml
```

Expected sequence over ~3-5 minutes: HPA CPU% climbs past 50% → replicas
scale 2→8 → new pods go `Pending` once the first workload node is full →
Cluster Autoscaler logs detect pending pods → workload ASG
`DesiredCapacity` goes 1→2 → second node joins → pending pods schedule.

**Scale back down:**
```bash
kubectl delete -f k8s/sample-workload/load-generator.yaml
```
Watch HPA and Cluster Autoscaler bring things back down over the following
~10-15 minutes (Cluster Autoscaler has a conservative scale-down delay by
design, to avoid flapping).

---

## Playground Constraints Discovered

Everything below was learned empirically while building this and is baked
into the Terraform/scripts in this repo. Documented here so the reasoning
isn't lost.

| Constraint | Detail |
|---|---|
| Session length | ~3 hours max; **entire account wiped** after, including all resources |
| Regions | `us-east-1`, `us-east-2`, `us-west-2` only |
| EKS: `eks:CreateNodegroup` | **Explicit IAM deny** — managed node groups don't work at all. Must use self-managed ASG + `aws-auth` ConfigMap instead. |
| EKS: `eks:AssociateAccessPolicy`, `eks:UpdateAccessEntry`, `eks:DeleteAccessEntry` | **Explicit IAM deny** — the modern EKS Access Entry API is create-only on this account. Attempting to grant cluster access via `aws_eks_access_entry` + `aws_eks_access_policy_association` after cluster creation dead-ends permanently (can create an entry, but can never fix or remove it if wrong). |
| **Fix for cluster access** | Set `bootstrap_cluster_creator_admin_permissions = true` in the cluster's `access_config` block. This grants the creating IAM identity `system:masters` **at `CreateCluster` time**, sidestepping the blocked APIs entirely. Only takes effect at creation — changing it later forces a full cluster replacement. |
| `iam:UpdateAssumeRolePolicy` | **Explicit IAM deny** — can't update an IAM role's trust policy after creation. Use `terraform apply -replace=<resource>` to force delete+recreate instead of update. |
| EC2 instance types | `t1/t2/t3` `nano/micro/small/medium` only |
| EBS | `gp2` only, max 30 GB per volume |
| Account-wide cap | 6000 millicores (6 vCPU), 12288 MiB (12 GiB) total |
| Availability zone | `us-east-1e` is blocked — never use it |
| External Load Balancers | EKS cannot provision an external ELB/NLB for `type: LoadBalancer` Services or Ingress — use `ClusterIP` + `kubectl port-forward` instead |
| Terraform lifecycle gotcha | If a resource **B** `depends_on` resource **A**, and B has `create_before_destroy = true`, Terraform forces A into the same behavior. Putting CBD on the ASGs (which depend on the EKS cluster) blocked cluster replacement with `ResourceInUseException` (tried to create the new cluster before destroying the old one, and EKS cluster names must be unique). **Fix**: only the *launch templates* need CBD, not the ASGs. |
| NetworkPolicy enforcement | The default VPC CNI does **not** enforce NetworkPolicies at all — needs `aws_eks_addon "vpc_cni"` with `enableNetworkPolicy=true`, which deploys the `aws-eks-nodeagent` container onto every node. Confirmed working on this playground account (unlike the IAM-related blocks above). |

---

## Known Limitations (by design, for this lab context)

- **No persistent storage** — Prometheus/Grafana/Alertmanager use ephemeral
  storage (no PVC/EBS). Given the whole account resets every ~3 hours
  anyway, persistent volumes would add complexity for no benefit — all
  meaningful state (dashboards, alert rules, Helm values) lives in Git.
- **Single NAT Gateway** — not one per AZ. A real production deployment
  would use per-AZ NAT for HA; this is a cost/simplicity tradeoff
  appropriate for a learning environment.
- **No external Load Balancer** — playground-enforced; `ClusterIP` +
  `port-forward` substitutes for demo purposes. On a full AWS account,
  swap `service.type` to `LoadBalancer` in the ingress-nginx values.
- **Alertmanager has no external receiver wired up** (no Slack/email/etc.)
  — alerts fire and are visible in the Alertmanager UI, just not routed
  externally. Trivial to add a `slack_configs` block if needed.
- **Grafana admin password is a placeholder** (`ChangeMe123!`) — treat as a
  throwaway lab credential, never reuse.

---

## Session Log

See [docs/session-notes.md](docs/session-notes.md) for a running log of
what was done in each playground session.
