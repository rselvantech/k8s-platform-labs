#!/bin/bash

# Traefik Ingress Controller Installation Script
# Automates Helm installation with EKS-optimized configuration

set -e

# Configuration
NAMESPACE="traefik"
RELEASE_NAME="traefik"
HELM_CHART="traefik/traefik"
VALUES_FILE="traefik-values.yaml"

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

    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        error=1
    else
        print_info "Kubernetes cluster: Connected"
    fi

    if [ ! -f "$VALUES_FILE" ]; then
        print_error "Values file '$VALUES_FILE' not found in current directory"
        print_error "Make sure you run this script from the 'src' directory"
        error=1
    else
        print_info "Values file: $VALUES_FILE found"
    fi

    if [ $error -eq 1 ]; then
        print_error "Prerequisites check failed"
        exit 1
    fi

    print_success "Prerequisites check passed!"
}

# Add Helm repository
add_helm_repo() {
    print_header "Setting Up Helm Repository"

    print_info "Adding Traefik Helm repository..."
    helm repo add traefik https://traefik.github.io/charts 2>/dev/null || true

    print_info "Updating Helm repositories..."
    helm repo update

    print_success "Helm repository ready!"
}

# Create namespace
create_namespace() {
    print_header "Creating Namespace"

    print_info "Creating namespace: $NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    print_success "Namespace ready!"
}

# Install Traefik
install_traefik() {
    print_header "Installing Traefik Ingress Controller"

    print_info "Release name: $RELEASE_NAME"
    print_info "Namespace: $NAMESPACE"
    print_info "Configuration: EKS-optimized with dashboard"
    echo ""

    if helm list -n "$NAMESPACE" | grep -q "$RELEASE_NAME"; then
        print_info "Traefik already installed. Upgrading..."
        helm upgrade "$RELEASE_NAME" "$HELM_CHART" \
            --namespace "$NAMESPACE" \
            --values "$VALUES_FILE"
    else
        print_info "Installing Traefik..."
        helm install "$RELEASE_NAME" "$HELM_CHART" \
            --namespace "$NAMESPACE" \
            --values "$VALUES_FILE"
    fi

    print_success "Helm installation complete!"
}

# Wait for Traefik to be ready
wait_for_traefik() {
    print_header "Waiting for Traefik to be Ready"

    print_info "Waiting for deployment to be available..."
    kubectl wait --for=condition=available \
        --timeout=300s \
        deployment/traefik \
        -n "$NAMESPACE"

    print_info "Waiting for LoadBalancer to provision..."
    echo "This may take 1-2 minutes while AWS provisions the NLB..."
    
    # Wait for external IP
    for i in {1..60}; do
        EXTERNAL_IP=$(kubectl get svc traefik -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
        if [ -n "$EXTERNAL_IP" ]; then
            print_success "LoadBalancer ready: $EXTERNAL_IP"
            break
        fi
        sleep 5
    done

    if [ -z "$EXTERNAL_IP" ]; then
        print_error "LoadBalancer IP not assigned after 5 minutes"
        print_error "Check AWS console or run: kubectl describe svc traefik -n $NAMESPACE"
    fi

    print_success "Traefik is ready!"
}

# Verify installation
verify_installation() {
    print_header "Verifying Installation"

    print_info "Traefik deployment:"
    kubectl get deployment traefik -n "$NAMESPACE"

    echo ""
    print_info "Traefik pods:"
    kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=traefik

    echo ""
    print_info "Traefik service:"
    kubectl get svc traefik -n "$NAMESPACE"

    echo ""
    print_info "IngressClass:"
    kubectl get ingressclass traefik

    echo ""
    print_info "Custom Resource Definitions (CRDs):"
    kubectl get crd | grep traefik

    print_success "Installation verified!"
}

# Print access instructions
print_access_instructions() {
    print_header "Next Steps"

    EXTERNAL_IP=$(kubectl get svc traefik -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "pending")

    cat << EOF
Traefik Ingress Controller has been successfully installed.

Access the Traefik Dashboard:

1. Port-forward to Traefik dashboard:
   kubectl port-forward -n $NAMESPACE svc/traefik 9000:9000

2. Open dashboard in browser:
   http://localhost:9000/dashboard/

3. LoadBalancer endpoint (for Ingress resources):
   $EXTERNAL_IP

Next steps:
- View Traefik logs: kubectl logs -n $NAMESPACE deployment/traefik
- Check for errors: kubectl logs -n $NAMESPACE deployment/traefik | grep -i error
- Create Ingress resources with ingressClassName: traefik

For detailed validation steps, see ../README.md
EOF
    echo ""
}

# Main execution
main() {
    print_header "Traefik Ingress Controller Installation"

    echo "This script will install Traefik Ingress Controller"
    echo "with an EKS-optimized configuration."
    echo ""

    check_prerequisites
    add_helm_repo
    create_namespace
    install_traefik
    wait_for_traefik
    verify_installation
    print_access_instructions

    print_success "Installation completed successfully!"
}

# Run main function
main "$@"