#!/bin/bash

# Traefik Ingress Controller Cleanup Script
# Removes Helm release and namespace

set -e

# Configuration
NAMESPACE="traefik"
RELEASE_NAME="traefik"

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

print_warning() {
    echo "[WARNING] $1"
}

# Uninstall Helm release
uninstall_helm() {
    print_header "Uninstalling Helm Release"

    if helm list -n "$NAMESPACE" | grep -q "$RELEASE_NAME"; then
        print_info "Uninstalling $RELEASE_NAME..."
        helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"
        print_success "Helm release uninstalled"
    else
        print_info "Helm release not found (already removed or never installed)"
    fi
}

# Delete namespace
delete_namespace() {
    print_header "Deleting Namespace"

    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        print_info "Deleting namespace: $NAMESPACE"
        print_warning "This will delete all resources in the namespace"
        kubectl delete namespace "$NAMESPACE" --wait=true
        print_success "Namespace deleted"
    else
        print_info "Namespace not found (already removed)"
    fi
}

# Clean up CRDs (optional)
cleanup_crds() {
    print_header "Checking Custom Resource Definitions"

    print_warning "Traefik CRDs are cluster-wide and may be used by other Traefik instances"
    print_warning "Skipping CRD deletion for safety"
    print_info "To manually delete CRDs if needed:"
    echo "  kubectl get crd | grep traefik"
    echo "  kubectl delete crd <crd-name>"
}

# Verify cleanup
verify_cleanup() {
    print_header "Verifying Cleanup"

    print_info "Checking for remaining resources..."

    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        print_warning "Namespace still exists!"
    else
        print_info "✓ Namespace removed"
    fi

    if kubectl get deployment traefik -n "$NAMESPACE" &>/dev/null 2>&1; then
        print_warning "Traefik deployment still exists!"
    else
        print_info "✓ Traefik deployment removed"
    fi

    if kubectl get svc traefik -n "$NAMESPACE" &>/dev/null 2>&1; then
        print_warning "Traefik service still exists!"
    else
        print_info "✓ Traefik service removed"
    fi

    # Check if LoadBalancer was deleted from AWS
    print_info "Note: AWS NLB deletion may take a few minutes to complete in AWS console"

    if kubectl get ingressclass traefik &>/dev/null; then
        print_warning "IngressClass 'traefik' still exists (may be cluster-scoped)"
        print_info "To delete manually: kubectl delete ingressclass traefik"
    else
        print_info "✓ IngressClass removed"
    fi

    print_success "Verification complete"
}

# Main execution
main() {
    print_header "Traefik Ingress Controller Cleanup"

    cat << EOF
This script will remove:
  - Helm release (traefik)
  - Namespace (traefik) and all resources in it
  - AWS Network Load Balancer (will be deleted automatically)

Traefik CRDs will NOT be deleted (cluster-wide resources).

EOF
    read -p "Continue? (y/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cleanup cancelled"
        exit 0
    fi

    uninstall_helm
    delete_namespace
    cleanup_crds
    verify_cleanup

    print_success "Cleanup completed!"
    
    cat << EOF

If you want to reinstall later, run:
  ./install-traefik-controller.sh

EOF
}

# Run main function
main "$@"