# Demo-02: Install Traefik Ingress Controller

## Demo Overview

This hands-on demo installs Traefik Proxy as a Kubernetes Ingress Controller in your EKS cluster. Traefik is a modern, cloud-native ingress controller that provides advanced routing, middleware capabilities, and a comprehensive dashboard for monitoring and management.

**What you'll do:**
- Install Traefik using Helm with custom configuration
- Configure Traefik for AWS EKS environment
- Access the Traefik dashboard
- Verify Traefik is ready to handle Ingress resources
- Compare Traefik's approach vs AWS Load Balancer Controller

## Prerequisites

**From Previous Demos:**
- ✅ Completed `00-otel-demo-app` - OTel Demo running in EKS cluster
- ✅ Completed `01-aws-alb-controller` - AWS LB Controller installed (both controllers will coexist)

**Required Tools:**
- kubectl v1.27+
- helm v3.12+

**Knowledge Requirements:**
- Understanding of Kubernetes Ingress concepts
- Basic knowledge of load balancers and routing
- Familiarity with Kubernetes Services

## Demo Objectives

By the end of this demo, you will be able to:

1. ✅ Understand Traefik architecture and components
2. ✅ Install Traefik using Helm with proper configuration for EKS
3. ✅ Access and navigate the Traefik dashboard
4. ✅ Verify Traefik installation and functionality
5. ✅ Understand differences between Traefik and AWS Load Balancer Controller

## Traefik Ingress Controller

### What It Does

Traefik is a modern HTTP reverse proxy and load balancer for microservices:
- **Ingress**: Standard Kubernetes Ingress support
- **IngressRoute**: Traefik's enhanced CRD for advanced routing
- **Middleware**: Extensible request/response modification
- **Gateway API**: Beta support for Kubernetes Gateway API

**Key Features:**
- Native Kubernetes integration
- Real-time configuration updates (no restarts)
- Built-in Let's Encrypt support
- Advanced routing (path, host, header, method-based)
- Middleware (auth, rate-limiting, circuit breakers)
- Metrics and tracing integration
- Web UI dashboard
- Multi-provider support (Kubernetes, Docker, Consul, etc.)

**Version Information:**
- Traefik: v3.6.7
- Helm Chart: 39.0.0
- Helm: 3.19.0
- Kubernetes: 1.27+
- EKS: 1.33

### Architecture

```
User Request (HTTP/HTTPS)
         ↓
   AWS Load Balancer (NLB/ELB)
   (One LB for all services)
         ↓
   Traefik Service (LoadBalancer)
         ↓
   Traefik Pods (Ingress Controller)
         ↓
   Kubernetes Pods (OTel Demo Services)
```

**Traefik Components:**
- Deployment in `traefik` namespace
- Service (LoadBalancer type) - single AWS NLB
- IngressClass for standard Ingress
- Custom Resources (IngressRoute, Middleware, etc.)
- Dashboard (optional, for monitoring)
- Metrics endpoint (Prometheus compatible)

**Key Difference from AWS LB Controller:**
- **Traefik**: One load balancer for ALL Ingress resources
- **AWS LB Controller**: One ALB per Ingress resource (by default)

## Directory Structure

```
02-install-traefik-controller/
├── README.md                           # This file
└── src/
    ├── traefik-values.yaml             # Helm values - EKS-optimized configuration
    ├── install-traefik-controller.sh   # Automated installation script
    └── cleanup-traefik-controller.sh   # Cleanup script
```

**File Roles:**
- `traefik-values.yaml` - Helm values configuring Traefik for EKS (NLB, dashboard, metrics, 2 replicas)
- `install-traefik-controller.sh` - Automates entire installation (Helm repo + install + verification)
- `cleanup-traefik-controller.sh` - Removes Traefik, namespace, and AWS NLB

# Demo Instructions

## Step 1: Understand Traefik Configuration

**1.1 Review Traefik's deployment model:**

Traefik runs as pods that watch for Kubernetes resources:
- Watches Ingress resources
- Watches IngressRoute (Traefik CRD)
- Watches Services and Endpoints
- Dynamically updates routing without restarts

**1.2 Understand EntryPoints:**

EntryPoints are network entry points into Traefik:
- `web`: HTTP (port 80)
- `websecure`: HTTPS (port 443)
- `traefik`: Dashboard/API (port 9000)


## Step 2: Install Traefik Ingress Controller

You can install using either the automated script OR manual Helm commands.

## Step 2.1: Install Using Script (Recommended)

**2.1.1 Run the installation script:**

```bash
cd 02-install-traefik-controller/src
chmod +x install-traefik-controller.sh
./install-traefik-controller.sh
```

The script automates:
- ✅ Prerequisites check (kubectl, helm)
- ✅ Helm repository setup (traefik/traefik)
- ✅ Namespace creation (traefik)
- ✅ Helm installation with EKS-optimized values
- ✅ Wait for deployment and LoadBalancer provisioning
- ✅ Basic verification (deployment, service, IngressClass, CRDs)

**Expected output:**
```
================================================
  Traefik Ingress Controller Installation
================================================

[INFO] kubectl: Client Version: v1.29.0
[INFO] helm: v3.14.0
[SUCCESS] Prerequisites check passed!

[INFO] Adding Traefik Helm repository...
[SUCCESS] Helm repository ready!

[INFO] Creating namespace: traefik
[SUCCESS] Namespace ready!

[INFO] Installing Traefik...
[SUCCESS] Helm installation complete!

[INFO] Waiting for deployment to be available...
[INFO] Waiting for LoadBalancer to provision...
This may take 1-2 minutes while AWS provisions the NLB...
[SUCCESS] LoadBalancer ready: a1234567890abcdef-1234567890.elb.us-east-2.amazonaws.com
[SUCCESS] Traefik is ready!

[SUCCESS] Installation completed successfully!
```

**2.1.2 Skip to Step 5 for validation.**

## Step 2.2:  Install Manually Using Helm

### Step 2.2.1: Add Traefik Helm Repository

**2.2.1.1 Add the official Traefik Helm repository:**

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
```

**2.2.1.2 Verify chart version:**

```bash
helm search repo traefik/traefik
```

**Expected output:**
```
NAME            CHART VERSION   APP VERSION   DESCRIPTION
traefik/traefik 39.0.0          v3.6.7          A Traefik based Kubernetes ingress controller
```

**2.2.1.3 View default values (optional):**

```bash
# See all configuration options
helm show values traefik/traefik > traefik-default-values.yaml
```

### Step 2.2.2: Create Custom Values File

Create `src/traefik-values.yaml`:

### Step 2.2.3:  Install Traefik

**2.2.3.1 Create namespace for Traefik:**

```bash
kubectl create namespace traefik
```

**2.2.3.2 Install Traefik using Helm:**

```bash
helm install traefik traefik/traefik \
  --namespace traefik \
  --values traefik-values.yaml
```

**Expected output:**
```
NAME: traefik
LAST DEPLOYED: ...
NAMESPACE: traefik
STATUS: deployed
REVISION: 1
TEST SUITE: None
```

**2.2.3.3  Verify Helm release:**

```bash
helm list -n traefik
```

## Step 5: Validate Installation

**5.1 Check Traefik deployment:**

```bash
kubectl get deployment -n traefik
```

**Expected output:**
```
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
traefik   2/2     2            2           1m
```

**5.2 Check pod status:**

```bash
kubectl get pods -n traefik
```

**Expected output:**
```
NAME                       READY   STATUS    RESTARTS   AGE
traefik-xxxxxxxxxx-xxxxx   1/1     Running   0          1m
traefik-xxxxxxxxxx-yyyyy   1/1     Running   0          1m
```

**5.3 Check Traefik Service:**

```bash
kubectl get svc -n traefik
```

**Expected output:**
```
NAME      TYPE           CLUSTER-IP      EXTERNAL-IP                                         PORT(S)
traefik   LoadBalancer   10.100.xx.xx    axxxxxxxxxxxxx.us-east-1.elb.amazonaws.com          80:3xxxx/TCP,443:3xxxx/TCP
```

**Important:** Note the `EXTERNAL-IP` - this is your AWS Network Load Balancer DNS name.


**5.4 Get LoadBalancer hostname:**
```bash
kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

**Expected output:**
```
axxxxxxxxxxxxx.us-east-1.elb.amazonaws.com
```

**5.4 Wait for Load Balancer to be ready:**

```bash
# This can take 2-3 minutes
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik --timeout=300s
```

**5.5 Check Traefik logs:**

```bash
kubectl logs -n traefik deployment/traefik --tail=50
```

**Look for success indicators:**
```
time="..." level=info msg="Configuration loaded from file: /etc/traefik/traefik.yaml"
time="..." level=info msg="Traefik version 3.2.0 built on..."
time="..." level=info msg="Starting provider *kubernetes.Provider"
time="..." level=info msg="Starting provider *kubernetescrd.Provider"
time="..." level=info msg="Server configuration reloaded on :8000"
time="..." level=info msg="Server configuration reloaded on :8443"
```

## Step 6: Verify IngressClass

**6.1 Check IngressClass creation:**

```bash
kubectl get ingressclass
```

**Expected output:**
```
NAME      CONTROLLER                    AGE
alb       ingress.k8s.aws/alb           XX
traefik   traefik.io/ingress-controller XX
```

**Note:** Both `alb` and `traefik` IngressClasses now exist!

**6.2 Describe Traefik IngressClass:**

```bash
kubectl describe ingressclass traefik
```

**Expected:**
```yaml
Name:         traefik
Labels:       app.kubernetes.io/name=traefik
Annotations:  <none>
Controller:   traefik.io/ingress-controller
```

### Step 7: Access Traefik Dashboard

**7.1 Set up port-forwarding to dashboard:**

```bash
kubectl port-forward -n traefik deployment/traefik 9000:9000
```

**7.2 Open dashboard in browser:**

```
http://localhost:9000/dashboard/
```

**Important:** The trailing slash `/` is required!

**7.3 Explore the dashboard:**

**Dashboard sections:**
- **EntryPoints**: Metrics (9100), traefik (9000) web (8000), websecure (8443)
- **HTTP Routers**: View all HTTP routes
- **HTTP Services**: Backend services  
- **Features**: Tracing (OFF), METRICS (Prometheus), ACCESSLOG (ON)
- **Providers**: KubernetesIngress, KubernetesCRD

**7.4 View Traefik metrics:**

```bash
# In a new terminal
kubectl port-forward -n traefik deployment/traefik 9100:9100

# Access metrics
curl http://localhost:9100/metrics
```

### Step 8: Verify Traefik CRDs

**8.1 Check Custom Resource Definitions:**

```bash
kubectl get crd | grep traefik
```

**Expected CRDs:**
```
ingressroutes.traefik.io
ingressroutetcps.traefik.io
ingressrouteudps.traefik.io
middlewares.traefik.io
middlewaretcps.traefik.io
serverstransports.traefik.io
serverstransporttcps.traefik.io
tlsoptions.traefik.io
tlsstores.traefik.io
traefikservices.traefik.io
```

These CRDs enable advanced Traefik features beyond standard Ingress.

### Step 9: Understanding Configuration

**9.1 View actual Traefik configuration:**

```bash
helm get values traefik -n traefik
```

**9.2 Important configuration concepts:**

**EntryPoints:**
- Define network entry points
- Each can have different settings (TLS, middleware, etc.)
- Metrics (9100), traefik (9000) web (8000), websecure (8443)

**Providers:**
- `kubernetesingress`: Standard Kubernetes Ingress
- `kubernetescrd`: Traefik's IngressRoute CRD
- Both enabled by default

**Service Type:**
- LoadBalancer creates AWS NLB
- Single NLB for all Ingress resources
- Cheaper than multiple ALBs

### Step 10: Test Basic Connectivity

**11.1 Get Traefik's Load Balancer DNS:**

```bash
export TRAEFIK_LB=$(kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "Traefik LB: $TRAEFIK_LB"
```

**11.2 Test connectivity:**

```bash
# Should return 404 (no routes configured yet)
curl http://$TRAEFIK_LB

# Expected: 404 page not found (this is correct - no Ingress resources yet)
```

**This 404 is expected!** Traefik is working, but we haven't created any Ingress resources yet.

## Troubleshooting

**Pods not starting:**
```bash
# Check events
kubectl describe pod -n traefik -l app.kubernetes.io/name=traefik

# Check logs
kubectl logs -n traefik deployment/traefik

# Common issues:
# - Image pull errors
# - Resource limits too low
# - Configuration errors in values.yaml
```

**CRDs not found:**
```bash
# Reinstall with CRDs
helm upgrade traefik traefik/traefik -n traefik --values traefik-values.yaml
```

## Cleanup

### Using Script (Recommended)

```bash
cd 02-install-traefik-controller/src
chmod +x cleanup-traefik-controller.sh
./cleanup-traefik-controller.sh
```

The script will prompt for confirmation, then remove:
- Helm release
- Namespace (traefik) and all resources
- AWS Network Load Balancer (auto-deleted when Service is removed)
- Note: CRDs are NOT deleted (cluster-wide, may be used elsewhere)

**Expected output:**
```
This script will remove:
  - Helm release (traefik)
  - Namespace (traefik) and all resources in it
  - AWS Network Load Balancer (will be deleted automatically)

Traefik CRDs will NOT be deleted (cluster-wide resources).

Continue? (y/N) y

[INFO] Uninstalling traefik...
[SUCCESS] Helm release uninstalled
[INFO] Deleting namespace: traefik
[SUCCESS] Namespace deleted
[WARNING] Traefik CRDs are cluster-wide and may be used by other Traefik instances
[WARNING] Skipping CRD deletion for safety
[SUCCESS] Cleanup completed!
```

**For Deleting CRDs check `Manual Cleanup` section below**


### Manual Cleanup

**1. Uninstall Helm release:**

```bash
helm uninstall traefik -n traefik
```

**2. Delete namespace:**

```bash
kubectl delete namespace traefik
```

This automatically deletes:
- Traefik deployment and pods
- Traefik LoadBalancer service
- AWS Network Load Balancer (takes a few minutes)
- All other resources in the namespace

**3. (Optional) Delete IngressClass:**

```bash
kubectl delete ingressclass traefik
```

**4. (Optional) Delete CRDs if no other Traefik instances exist:**

**When SHOULD You Delete CRDs?**

`Delete CRDs only when:`

✅ No other Traefik instances exist in the cluster

✅ No IngressRoutes, Middlewares, etc. exist in ANY namespace

✅ You're completely removing Traefik from the cluster

```bash
# List Traefik CRDs
kubectl get crd | grep traefik

# Delete all Traefik CRDs (CAUTION: cluster-wide)
kubectl get crd -o name | grep traefik | xargs kubectl delete
```

**5. Verify cleanup:**

```bash
# Check namespace removed
kubectl get namespace traefik
# Expected: Error from server (NotFound)

# Check deployment removed
kubectl get deployment traefik -n traefik
# Expected: Error from server (NotFound)

# Check LoadBalancer removed
kubectl get svc traefik -n traefik
# Expected: Error from server (NotFound)
```

**Note:** AWS NLB deletion appears in the AWS console within 1-2 minutes.


## Comparison with AWS Load Balancer Controller

**Review key differences:**

| Aspect | AWS LB Controller | Traefik |
|--------|------------------|---------|
| **Load Balancer** | One ALB per Ingress | One NLB for all Ingress |
| **Cost** | $16-25/month per ALB | ~$16/month total (one NLB) |
| **Provisioning** | 2-3 minutes per ALB | Instant (uses existing LB) |
| **AWS Integration** | Native (WAF, ACM, Cognito) | Basic (NLB only) |
| **Advanced Routing** | Annotations | CRDs (IngressRoute) |
| **Middleware** | Limited | Extensive (auth, rate-limit, etc.) |
| **Dashboard** | No | Yes (built-in) |
| **Multi-cloud** | AWS only | Any Kubernetes |
| **Configuration** | Annotations | CRDs + Annotations |

**10.2 When to use each:**

**Use AWS LB Controller when:**
- Need AWS-specific features (WAF, ACM, Cognito)
- Want ALB per application for isolation
- Compliance requires AWS-native services
- Using multiple AZs with specific routing

**Use Traefik when:**
- Cost optimization (single LB)
- Need advanced middleware
- Want real-time config updates
- Prefer dashboard for monitoring
- Multi-cloud portability

## Key Concepts Explained

### EntryPoints
- Network entry points into Traefik
- Define ports and protocols
- Can have different configurations (TLS, middleware)
- Examples: web (HTTP), websecure (HTTPS), traefik (dashboard)

### Providers
- Sources of configuration
- `kubernetesingress`: Standard Kubernetes Ingress
- `kubernetescrd`: Traefik's enhanced routing (IngressRoute)
- Providers can be combined

### IngressRoute (Traefik CRD)
- Traefik's enhanced Ingress resource
- More powerful than standard Ingress
- Supports advanced routing rules
- Can chain multiple middleware

### Middleware
- Process requests/responses
- Examples: authentication, rate-limiting, headers
- Reusable across routes
- Chainable (multiple middleware per route)

### Single Load Balancer Model
- One NLB serves all Ingress resources
- Traefik does the routing internally
- More cost-effective than ALB-per-Ingress
- Faster updates (no AWS API calls)

## Validation Checklist

Before proceeding to the next demo, verify:

- [ ] Traefik deployment shows 2/2 READY
- [ ] Both Traefik pods are Running
- [ ] Traefik Service has EXTERNAL-IP (AWS NLB)
- [ ] IngressClass `traefik` exists
- [ ] Dashboard accessible via port-forward
- [ ] Traefik logs show no errors
- [ ] All Traefik CRDs are installed
- [ ] Both ALB and Traefik IngressClasses coexist

## What You Learned

In this demo, you:
- ✅ Installed Traefik using Helm with EKS-optimized configuration
- ✅ Configured Traefik with proper EntryPoints and providers
- ✅ Accessed and explored the Traefik dashboard
- ✅ Verified Traefik is operational with AWS NLB
- ✅ Understood Traefik CRDs and advanced features
- ✅ Compared Traefik architecture with AWS Load Balancer Controller
- ✅ Learned when to use each controller

## Next Steps

**Demo 1.3: Expose Frontend with Both Controllers**
- Create Ingress resources for both ALB and Traefik
- Compare provisioning and behavior
- Access OTel Demo frontend via both controllers

## Additional Resources

- Traefik Documentation: https://doc.traefik.io/traefik/
- Traefik Helm Chart: https://github.com/traefik/traefik-helm-chart
- Traefik on Kubernetes: https://doc.traefik.io/traefik/providers/kubernetes-ingress/
- IngressRoute Documentation: https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/
