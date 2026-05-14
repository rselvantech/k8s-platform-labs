# Demo-01: Install AWS Load Balancer Controller

## Demo Overview

This hands-on demo installs the AWS Load Balancer Controller in your EKS cluster. The controller provisions AWS Application Load Balancers (ALBs) when you create Kubernetes Ingress resources, providing AWS-native load balancing for your applications.

**What you'll do:**
- Set up IAM policies and roles with IRSA (IAM Roles for Service Accounts)
- Install the AWS Load Balancer Controller using Helm
- Verify the controller is running and ready
- Understand how the controller integrates with AWS services

## Prerequisites

**From Previous Demos:**
- ✅ Completed `00-otel-demo-app` - OTel Demo running in EKS cluster

**Required Tools:**
- AWS CLI v2
- kubectl v1.27+
- helm v3.12+
- eksctl (for IRSA creation)
- jq (for JSON parsing)

**AWS Requirements:**
- IAM permissions to create policies and roles
- EKS cluster with proper subnet tagging

**Knowledge Requirements:**
- Understanding of Kubernetes Ingress concepts
- Basic AWS IAM knowledge (policies, roles)
- Familiarity with IRSA (IAM Roles for Service Accounts)

## Demo Objectives

By the end of this demo, you will be able to:

1. ✅ Understand AWS Load Balancer Controller architecture
2. ✅ Configure IAM policies and IRSA for the controller
3. ✅ Install the controller using Helm with proper configuration
4. ✅ Verify the controller installation and functionality
5. ✅ Understand how the controller provisions AWS ALBs

## AWS Load Balancer Controller

### What It Does

The AWS Load Balancer Controller manages AWS Elastic Load Balancers for Kubernetes:
- **Ingress**: Provisions Application Load Balancers (ALBs)
- **Service (LoadBalancer)**: Provisions Network Load Balancers (NLBs)
- **Gateway API**: Provisions both ALBs and NLBs (Beta)

**Key Features:**
- Native AWS integration (WAF, ACM, Cognito, Security Groups)
- Advanced routing (path, host, header-based)
- Multiple target types (instance, IP)
- Health checks and monitoring via CloudWatch
- SSL/TLS termination with ACM

**Version Information:**
- AWS Load Balancer Controller: v3.0.0 (as of January 2026)
- Helm Chart: 3.0.0
- Helm: 3.19.0
- Kubernetes: 1.27+
- EKS: 1.33

### Architecture

```
User Request (HTTP/HTTPS)
         ↓
   AWS Application Load Balancer (ALB)
   (Created by Controller)
         ↓
   Target Group (IP or Instance mode)
         ↓
   Kubernetes Pods (OTel Demo Services)
```

**Controller Components:**
- Deployment in `kube-system` namespace
- Webhook for Ingress/Service validation
- ServiceAccount with IRSA
- Watches for Ingress/Service resources
- Reconciles with AWS APIs

## Directory Structure

```
01-install-aws-alb-controller/
├── README.md                           # This file
└── src/
    ├── iam_policy.json                 # IAM policy (downloaded by script)
    ├── install-alb-controller.sh       # Automated installation script
    └── cleanup-alb-controller.sh       # Cleanup script
```

**File Roles:**
- `iam_policy.json` - Auto-downloaded from AWS LB Controller GitHub, defines required IAM permissions
- `install-alb-controller.sh` - Automates entire installation (IAM policy + IRSA + Helm install)
- `cleanup-alb-controller.sh` - Removes controller, ServiceAccount, IAM role, and IAM policy

## Demo Instructions

### Step 1: Understand IAM Requirements

**1.1 Review what IAM permissions the controller needs:**

The controller requires permissions to:
- Create/modify/delete ALBs and NLBs
- Manage target groups
- Configure listeners and rules
- Attach security groups
- Manage tags

**1.2 Review IAM Policy Document:**

```bash
# View the official IAM policy
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.0.0/docs/install/iam_policy.json

# Quick review of key permissions
cat iam_policy.json | jq '.Statement[].Action' | head -20
```

**Key Permission Groups:**
- `elasticloadbalancing:*` - Manage load balancers
- `ec2:*` - VPC, subnet, security group operations
- `wafv2:*` - AWS WAF integration
- `shield:*` - AWS Shield integration
- `acm:*` - Certificate management

### Step 2: Preparation & Installing AWS Load Balancer Controller

You can create IAM policy and install  using either the automated script OR manually using commands.

## Step 2.1: Install Using Script (Recommended)

**2.1.1 Run the installation script:**

```bash
cd 01-install-aws-alb-controller/src
chmod +x install-alb-controller.sh
./install-alb-controller.sh
```

The script automates:
- ✅ Prerequisites check (AWS CLI, kubectl, helm, eksctl)
- ✅ Cluster name detection
- ✅ IAM policy download and creation (skips if exists)
- ✅ IRSA creation (ServiceAccount + IAM role)
- ✅ Helm installation with correct parameters
- ✅ Wait for controller to be ready
- ✅ Basic verification

**Expected output:**
```
================================================
  AWS Load Balancer Controller Installation
================================================

[INFO] kubectl: Client Version: v1.29.0
[INFO] helm: v3.14.0
[INFO] eksctl: 0.175.0
[SUCCESS] Prerequisites check passed!

[INFO] Cluster Name: otel-demo-3
[INFO] AWS Account: 123456789012
[INFO] AWS Region: us-east-2

[INFO] Downloading IAM policy document...
[INFO] Creating IAM policy...
[SUCCESS] IAM policy created: arn:aws:iam::123456789012:policy/AWSLoadBalancerControllerIAMPolicy

[INFO] Creating ServiceAccount with IAM role...
[SUCCESS] IRSA created successfully

[INFO] Installing controller...
[SUCCESS] Helm installation complete!

[INFO] Waiting for deployment to be available...
[SUCCESS] Controller is ready!

[SUCCESS] Installation completed successfully!
```

**2.1.2 Skip to Step 5 for validation.**

---

## Step 2.2: Install Manually Using Helm

### Create IAM Policy

**2.2.1 Download the latest IAM policy:**

```bash
# For standard AWS regions
curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.0.0/docs/install/iam_policy.json

# For AWS GovCloud
# curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.0.0/docs/install/iam_policy_us-gov.json

# For AWS China regions
# curl -o iam-policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.0.0/docs/install/iam_policy_cn.json
```

**2.2.2 Create the IAM policy:**

```bash
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam_policy.json
```

**Expected output:**
```json
{
    "Policy": {
        "PolicyName": "AWSLoadBalancerControllerIAMPolicy",
        "PolicyId": "ANPA...",
        "Arn": "arn:aws:iam::123456789012:policy/AWSLoadBalancerControllerIAMPolicy",
        "CreateDate": "2025-01-31T..."
    }
}
```

**2.2.3 Save the Policy ARN:**

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"
echo $POLICY_ARN
```

### Create IAM Role with IRSA

**2.2.4 Understand IRSA (IAM Roles for Service Accounts):**

IRSA allows Kubernetes ServiceAccounts to assume AWS IAM roles:
- Pods use ServiceAccount tokens
- OIDC provider maps ServiceAccount to IAM role
- No need for AWS credentials in pods
- Fine-grained permissions per ServiceAccount

**2.2.5 Get your cluster name:**

```bash
export CLUSTER_NAME=$(eksctl get cluster -o json | jq -r '.[0].Name')
echo "Cluster: $CLUSTER_NAME"
```

**2.2.6 Create the IAM role and ServiceAccount:**

```bash
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=$POLICY_ARN \
  --override-existing-serviceaccounts \
  --approve
```

**What this does:**
- Creates IAM role: `eksctl-<cluster>-addon-iamserviceaccount-kube-system-aws-load-balancer-controller`
- Creates Kubernetes ServiceAccount with annotation: `eks.amazonaws.com/role-arn`
- Sets up trust relationship between OIDC provider and role

**2.2.7 Verify the ServiceAccount:**

```bash
kubectl get serviceaccount aws-load-balancer-controller -n kube-system -o yaml
```

**Expected annotation:**
```yaml
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/eksctl-...
```

### Install AWS Load Balancer Controller with Helm

**2.2.8 Add the EKS Helm chart repository:**

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update
```

**2.2.9 Verify chart version:**

```bash
helm search repo eks/aws-load-balancer-controller
```

**Expected output:**
```
NAME                               CHART VERSION   APP VERSION   DESCRIPTION
eks/aws-load-balancer-controller   1.11.0          v2.14.1       AWS Load Balancer Controller...
```

**2.2.10 Install the controller:**

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```

**Important flags:**
- `--set serviceAccount.create=false` - Use existing ServiceAccount with IRSA
- `--set serviceAccount.name=aws-load-balancer-controller` - Match the IRSA ServiceAccount name
- `--set clusterName=$CLUSTER_NAME` - Required for controller to identify its cluster

**Expected output:**
```
NAME: aws-load-balancer-controller
LAST DEPLOYED: ...
NAMESPACE: kube-system
STATUS: deployed
REVISION: 1
```

**2.2.11 Verify Helm release:**

```bash
helm list -n kube-system
```

## Step 5: Validate Installation

**5.1 Check controller pods:**

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
```

**Expected output:**
```
NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
aws-load-balancer-controller   2/2     2            2           1m
```

**Note:** You should see **2/2** replicas (high availability by default)

**5.2 Check pod status:**

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

**Expected output:**
```
NAME                                            READY   STATUS    RESTARTS   AGE
aws-load-balancer-controller-xxxxx-xxxxx        1/1     Running   0          1m
aws-load-balancer-controller-xxxxx-yyyyy        1/1     Running   0          1m
```

**5.3 Check controller logs:**

```bash
kubectl logs -n kube-system deployment/aws-load-balancer-controller --tail=50
```

**Look for these success indicators:**
```
"msg":"version","version":"v3.0.0"
"msg":"kubebuilder/controller-runtime","version":"v0.xx.x"
"msg":"controller/ingress-class-params-reconciler","Starting Controller"
"msg":"controller/target-group-binding-reconciler","Starting Controller"
"msg":"Starting workers","worker count":10
```

**5.4 Verify webhook configuration:**

```bash
kubectl get validatingwebhookconfiguration | grep aws-load-balancer-webhook
```

**Expected output:**
```
aws-load-balancer-webhook-validating   1          1m
```

**5.5 Check IngressClass:**

```bash
kubectl get ingressclass
```

**Expected output:**
```
NAME   CONTROLLER                    AGE
alb    ingress.k8s.aws/alb           1m
```

## Step 6: Verify AWS Integration

**6.1 Check controller can communicate with AWS:**

```bash
# View controller logs for AWS API calls
kubectl logs -n kube-system deployment/aws-load-balancer-controller | grep -i "aws"
```

**Look for:**
- No authentication errors
- Successful API calls
- VPC/subnet discovery messages

**6.2 Verify IAM role assumption:**

```bash
# Check pod environment for AWS role
kubectl exec -n kube-system deployment/aws-load-balancer-controller -- env | grep AWS
```

**Expected variables:**
```
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/eksctl-...
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
AWS_REGION=us-east-1
```

## Step 7: Understanding Controller Configuration

**7.1 View all controller configuration:**

```bash
helm get values aws-load-balancer-controller -n kube-system
```

**7.2 Important controller flags (set via Helm):**

```yaml
USER-SUPPLIED VALUES:
clusterName: <your-cluster>  # Required
serviceAccount:
  create: false              # Using IRSA ServiceAccount
  name: aws-load-balancer-controller

# Additional common options (usually we do not set these explicitly , they get below default values)
# replicaCount: 2              # High availability
# ingressClass: alb          # Default IngressClass name
# enableShield: false        # AWS Shield integration
# enableWaf: false           # AWS WAF integration
# enableWafv2: false         # AWS WAFv2 integration
```

**7.3 View controller command-line flags:**

```bash
kubectl describe deployment aws-load-balancer-controller -n kube-system | grep -A 20 "Args:"
```

## Step 8: Verify Prerequisites for ALB Creation

**8.1 Check subnet tagging:**

For the controller to auto-discover subnets:

```bash
# Get VPC ID
export VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.resourcesVpcConfig.vpcId" --output text)

# Check public subnet tags
aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[*].[SubnetId,Tags[?Key==`kubernetes.io/role/elb`].Value|[0]]' --output table
```

**Required tags for public subnets:**
- `kubernetes.io/role/elb` = `1`
- `kubernetes.io/cluster/<cluster-name>` = `shared` or `owned`

**Required tags for private subnets:**
- `kubernetes.io/role/internal-elb` = `1`
- `kubernetes.io/cluster/<cluster-name>` = `shared` or `owned`

**8.2 Verify security groups:**

```bash
# Controller needs to modify security groups
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" --query 'SecurityGroups[*].[GroupId,GroupName]' --output table
```

## Troubleshooting

**IRSA authentication errors:**
```bash
# Verify OIDC provider exists
aws eks describe-cluster --name $CLUSTER_NAME --query "cluster.identity.oidc.issuer" --output text

# Verify role trust relationship
aws iam get-role --role-name <role-name> --query 'Role.AssumeRolePolicyDocument'
```

**Webhook errors:**
```bash
# Check webhook endpoint is reachable
kubectl get endpoints -n kube-system aws-load-balancer-webhook-service

# Verify webhook certificate
kubectl get secret -n kube-system aws-load-balancer-tls
```

**Subnet discovery failures:**
```bash
# Controller logs will show
kubectl logs -n kube-system deployment/aws-load-balancer-controller | grep -i subnet

# Fix: Add required tags to subnets
```

## Cleanup

### Using Script (Recommended)

```bash
cd 01-install-aws-alb-controller/src
chmod +x cleanup-aws-alb-controller.sh
./cleanup-aws-alb-controller.sh
```

The script will prompt for confirmation, then remove:
- Helm release
- Kubernetes ServiceAccount
- IAM Role (created by IRSA)
- IAM Policy (if not attached to other roles)
- Downloaded `iam_policy.json` file

**Expected output:**
```
This script will remove:
  - Helm release (aws-load-balancer-controller)
  - Kubernetes ServiceAccount
  - IAM Role (created by IRSA)
  - IAM Policy (AWSLoadBalancerControllerIAMPolicy)

Continue? (y/N) y

[INFO] Uninstalling aws-load-balancer-controller...
[SUCCESS] Helm release uninstalled
[INFO] Deleting ServiceAccount and associated IAM role...
[SUCCESS] IRSA deleted
[INFO] Deleting IAM policy...
[SUCCESS] IAM policy deleted
[SUCCESS] Cleanup completed!
```

### Manual Cleanup

**1. Uninstall Helm release:**

```bash
helm uninstall aws-load-balancer-controller -n kube-system
```

**2. Delete ServiceAccount and IAM role:**

```bash
eksctl delete iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --wait
```

**3. Delete IAM policy (optional):**

```bash
# Get policy ARN
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

# Check if policy is attached to any roles
aws iam list-entities-for-policy --policy-arn $POLICY_ARN

# If not attached(it will not be), delete it
aws iam delete-policy --policy-arn $POLICY_ARN
```

**4. Verify cleanup:**

```bash
# Check deployment removed
kubectl get deployment aws-load-balancer-controller -n kube-system
# Expected: Error from server (NotFound)

# Check ServiceAccount removed
kubectl get serviceaccount aws-load-balancer-controller -n kube-system
# Expected: Error from server (NotFound)

# Check IngressClass removed
kubectl get ingressclass alb
# Expected: Error from server (NotFound)
```

## Key Concepts Explained

### IRSA (IAM Roles for Service Accounts)
- Maps Kubernetes ServiceAccounts to AWS IAM roles
- Uses OIDC provider for authentication
- Eliminates need for AWS credentials in pods
- Provides fine-grained, pod-level permissions

### IngressClass
- Kubernetes resource that identifies which controller handles an Ingress
- ALB controller creates `ingressClass: alb`
- Multiple controllers can coexist (ALB, NGINX, Traefik)
- Ingress resources specify which class to use

### Target Types
- **IP mode**: Targets pod IPs directly (recommended)
- **Instance mode**: Targets EC2 instances (legacy)
- Configured via annotation: `alb.ingress.kubernetes.io/target-type: ip`

### Webhook
- Validates Ingress and Service resources before creation
- Prevents invalid configurations
- Provides better error messages
- Required component for controller operation

## Validation Checklist

Before proceeding to the next demo, verify:

- [ ] Controller deployment shows 2/2 READY
- [ ] Both controller pods are Running
- [ ] Logs show no authentication errors
- [ ] IngressClass `alb` exists
- [ ] Webhook is configured and healthy
- [ ] IRSA ServiceAccount has correct role annotation
- [ ] Subnets are properly tagged for auto-discovery
- [ ] No errors in controller logs

## What You Learned

In this demo, you:
- ✅ Created IAM policy for AWS Load Balancer Controller
- ✅ Configured IRSA for secure AWS API access
- ✅ Installed the controller using Helm with proper configuration
- ✅ Verified controller is operational and communicating with AWS
- ✅ Understood controller architecture and AWS integration
- ✅ Learned about IngressClass and webhook components

## Next Steps

**Demo 1.2: Install Traefik Ingress Controller**
- Install Traefik as alternative/complementary controller
- Compare architecture with AWS LB Controller
- Access Traefik dashboard

## Additional Resources

- AWS Load Balancer Controller Documentation: https://kubernetes-sigs.github.io/aws-load-balancer-controller/
- GitHub Repository: https://github.com/kubernetes-sigs/aws-load-balancer-controller
- AWS EKS Best Practices: https://aws.github.io/aws-eks-best-practices/
- Helm Chart: https://github.com/aws/eks-charts/tree/master/stable/aws-load-balancer-controller



