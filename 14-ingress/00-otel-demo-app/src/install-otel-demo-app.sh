#!/bin/bash

# OpenTelemetry Demo App Installation Script
# Deploys a minimal OTel Demo configuration for Ingress learning

set -e

# Configuration
NAMESPACE="${1:-otel-demo}"
RELEASE_NAME="${2:-otel-demo}"
HELM_REPO_URL="https://open-telemetry.github.io/opentelemetry-helm-charts"
CHART_NAME="opentelemetry-demo"
VALUES_FILE="otel-demo-app-values.yaml"

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
        print_error "kubectl not found. Please install kubectl first."
        error=1
    else
        print_info "kubectl: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    fi

    if ! command -v helm &> /dev/null; then
        print_error "helm not found. Please install helm first."
        error=1
    else
        print_info "helm: $(helm version --short)"
    fi

    # Check kubectl can connect to cluster
    if ! kubectl cluster-info &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster. Check your kubeconfig."
        error=1
    else
        print_info "Kubernetes cluster: Connected"
    fi

    # Check values file exists
    if [ ! -f "$VALUES_FILE" ]; then
        print_error "Values file '$VALUES_FILE' not found in current directory"
        print_error "Make sure you run this script from the 'src' directory"
        error=1
    else
        print_info "Values file: $VALUES_FILE found"
    fi

    if [ $error -eq 1 ]; then
        print_error "Prerequisites check failed. Please fix the above issues."
        exit 1
    fi

    print_success "Prerequisites check passed!"
}

# Add Helm repository
add_helm_repo() {
    print_header "Setting Up Helm Repository"

    print_info "Adding OpenTelemetry Helm repository..."
    helm repo add open-telemetry "$HELM_REPO_URL" 2>/dev/null || true

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

# Install OTel Demo
install_demo() {
    print_header "Installing OpenTelemetry Demo"

    print_info "Release name: $RELEASE_NAME"
    print_info "Namespace: $NAMESPACE"
    print_info "Configuration: Minimal (essential services only)"
    echo ""

    print_info "Installing OpenTelemetry Demo..."
    print_info "This may take a few minutes..."
    echo ""

    helm install "$RELEASE_NAME" open-telemetry/$CHART_NAME \
        --version 0.40.2 \
        --namespace "$NAMESPACE" \
        --values "$VALUES_FILE"


    print_success "Installation complete!"
}

# Print access instructions
print_access_instructions() {
    print_header "Next Steps"

    cat << EOF
[INFO] The OpenTelemetry Demo has been deployed!

Monitor the deployment:
   kubectl get pods -n $NAMESPACE -w
   (Press Ctrl+C when all pods show Running)

Validate the deployment:
   kubectl get pods -n $NAMESPACE
   kubectl get svc -n $NAMESPACE

To access the applications, use port-forwarding:

1. Frontend (Astronomy Shop):
   kubectl port-forward -n $NAMESPACE svc/frontend-proxy 8080:8080
   Open: http://localhost:8080

2. Jaeger (Tracing UI):
   kubectl port-forward -n $NAMESPACE svc/jaeger 16686:16686
   Open: http://localhost:16686

3. Grafana (Dashboards):
   kubectl port-forward -n $NAMESPACE svc/grafana 3000:80
   Open: http://localhost:3000/grafana/
   Note: No login required (anonymous access enabled)

For detailed validation steps, see ../README
EOF
    echo ""
}

# Main execution
main() {
    print_header "OpenTelemetry Demo Installation"

    echo "This script will install the OpenTelemetry Demo Application"
    echo "with a minimal configuration optimized for Ingress learning."
    echo ""

    check_prerequisites
    add_helm_repo
    create_namespace
    install_demo
    print_access_instructions

    print_success "Installation started!"
}

# Run main function
main "$@"