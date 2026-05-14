#!/bin/bash

# AWS Load Balancer Controller Installation Script
# Automates IAM policy creation, IRSA setup, and Helm installation

set -e

# Configuration
CONTROLLER_VERSION="v3.0.0"
IAM_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"
NAMESPACE="kube-system"
HELM_CHART="eks/aws-load-balancer-controller"

# Print functions
print_header() {
    echo ""
    echo "================================================"
    echo "  $1"
    echo "================================================"
    echo ""
}

print_info() {
    echo "[INFO] $1"
}

print_error() {
    echo "[ERROR] $1"
}

print_success() {
    echo "[SUCCESS] $1"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    local error=0

    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found"
        error=1
    else
        print_info "AWS CLI: $(aws --version)"
    fi

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found"
        error=1
    else
        print_info "kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    fi

    if ! command -v helm &> /dev/null; then
        print_error "helm not found"
        error=1
    else
        print_info "helm: $(helm version --short)"
    fi

    if ! command -v eksctl &> /dev/null; then
        print_error "eksctl not found"
        error=1
    else
        print_info "eksctl: $(eksctl version)"
    fi

    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        error=1
    else
        print_info "Kubernetes cluster: Connected"
    fi

    if [ $error -eq 1 ]; then
        print_error "Prerequisites check failed"
        exit 1
    fi

    print_success "Prerequisites check passed!"
}

# Get cluster name
get_cluster_name() {
    print_header "Getting Cluster Information"

    CLUSTER_NAME=$(eksctl get cluster -o json | jq -r '.[0].Name')
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    #AWS_REGION=$(aws configure get region)

    print_info "Cluster Name: $CLUSTER_NAME"
    print_info "AWS Account: $AWS_ACCOUNT_ID"
    print_info "AWS Region: $AWS_REGION"
}

# Download and create IAM policy
create_iam_policy() {
    print_header "Creating IAM Policy"

    print_info "Downloading IAM policy document..."
    curl -sSL -o iam_policy.json \
        https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${CONTROLLER_VERSION}/docs/install/iam_policy.json

    print_info "Checking if policy already exists..."
    POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"
    
    if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
        print_info "Policy already exists: $POLICY_ARN"
    else
        print_info "Creating IAM policy..."
        aws iam create-policy \
            --policy-name "$IAM_POLICY_NAME" \
            --policy-document file://iam_policy.json \
            --description "IAM policy for AWS Load Balancer Controller"
        
        print_success "IAM policy created: $POLICY_ARN"
    fi

    export POLICY_ARN
}

# Create IRSA (IAM Role for Service Account)
create_irsa() {
    print_header "Creating IRSA (IAM Role for Service Account)"

    print_info "Creating ServiceAccount with IAM role..."
    
    eksctl create iamserviceaccount \
        --cluster="$CLUSTER_NAME" \
        --namespace="$NAMESPACE" \
        --name="$SERVICE_ACCOUNT_NAME" \
        --attach-policy-arn="$POLICY_ARN" \
        --override-existing-serviceaccounts \
        --approve

    print_success "IRSA created successfully"

    print_info "Verifying ServiceAccount..."
    kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE" -o yaml | grep eks.amazonaws.com/role-arn
}

# Install AWS Load Balancer Controller via Helm
install_controller() {
    print_header "Installing AWS Load Balancer Controller"

    print_info "Adding EKS Helm repository..."
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update

    print_info "Checking if controller is already installed..."
    if helm list -n "$NAMESPACE" | grep -q aws-load-balancer-controller; then
        print_info "Controller already installed. Upgrading..."
        helm upgrade aws-load-balancer-controller "$HELM_CHART" \
            -n "$NAMESPACE" \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=false \
            --set serviceAccount.name="$SERVICE_ACCOUNT_NAME"
    else
        print_info "Installing controller..."
        helm install aws-load-balancer-controller "$HELM_CHART" \
            -n "$NAMESPACE" \
            --set clusterName="$CLUSTER_NAME" \
            --set serviceAccount.create=false \
            --set serviceAccount.name="$SERVICE_ACCOUNT_NAME"
    fi

    print_success "Helm installation complete!"
}

# Wait for controller to be ready
wait_for_controller() {
    print_header "Waiting for Controller to be Ready"

    print_info "Waiting for deployment to be available..."
    kubectl wait --for=condition=available \
        --timeout=300s \
        deployment/aws-load-balancer-controller \
        -n "$NAMESPACE"

    print_success "Controller is ready!"
}

# Verify installation
verify_installation() {
    print_header "Verifying Installation"

    print_info "Controller deployment:"
    kubectl get deployment aws-load-balancer-controller -n "$NAMESPACE"

    echo ""
    print_info "Controller pods:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=aws-load-balancer-controller

    echo ""
    print_info "IngressClass:"
    kubectl get ingressclass

    echo ""
    print_info "Webhook configuration:"
    kubectl get validatingwebhookconfiguration | grep aws-load-balancer

    print_success "Installation verified!"
}

# Print next steps
print_next_steps() {
    print_header "Installation Complete!"

    cat << EOF
The AWS Load Balancer Controller has been successfully installed.

Next steps:
1. View controller logs:
   kubectl logs -n kube-system deployment/aws-load-balancer-controller

2. Check for any errors:
   kubectl logs -n kube-system deployment/aws-load-balancer-controller | grep -i error

3. Proceed to create Ingress resources to test the controller

For detailed validation steps, see ../README.md
EOF
}

# Main execution
main() {
    print_header "AWS Load Balancer Controller Installation"

    check_prerequisites
    get_cluster_name
    create_iam_policy
    create_irsa
    install_controller
    wait_for_controller
    verify_installation
    print_next_steps

    print_success "Installation completed successfully!"
}

# Run main function
main "$@"