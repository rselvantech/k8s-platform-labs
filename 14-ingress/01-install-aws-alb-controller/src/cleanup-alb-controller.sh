#!/bin/bash

# AWS Load Balancer Controller Cleanup Script
# Removes Helm release, IRSA, and IAM policy

set -e

# Configuration
IAM_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"
NAMESPACE="kube-system"

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

# Get cluster and account info
get_info() {
    print_header "Getting Cluster Information"

    CLUSTER_NAME=$(eksctl get cluster -o json | jq -r '.[0].Name')
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

    print_info "Cluster Name: $CLUSTER_NAME"
    print_info "AWS Account: $AWS_ACCOUNT_ID"
}

# Uninstall Helm release
uninstall_helm() {
    print_header "Uninstalling Helm Release"

    if helm list -n "$NAMESPACE" | grep -q aws-load-balancer-controller; then
        print_info "Uninstalling aws-load-balancer-controller..."
        helm uninstall aws-load-balancer-controller -n "$NAMESPACE"
        print_success "Helm release uninstalled"
    else
        print_info "Helm release not found (already removed or never installed)"
    fi
}

# Delete ServiceAccount and IAM role (IRSA)
delete_irsa() {
    print_header "Deleting IRSA (ServiceAccount + IAM Role)"

    if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE" &>/dev/null; then
        print_info "Deleting ServiceAccount and associated IAM role..."
        
        eksctl delete iamserviceaccount \
            --cluster="$CLUSTER_NAME" \
            --namespace="$NAMESPACE" \
            --name="$SERVICE_ACCOUNT_NAME" \
            --wait

        print_success "IRSA deleted"
    else
        print_info "ServiceAccount not found (already removed)"
    fi
}

# Delete IAM policy
delete_iam_policy() {
    print_header "Deleting IAM Policy"

    POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

    if aws iam get-policy --policy-arn "$POLICY_ARN" &>/dev/null; then
        print_warning "Checking for policy attachments..."
        
        # List all entities the policy is attached to
        ATTACHED=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyRoles[].RoleName' --output text)
        
        if [ -n "$ATTACHED" ]; then
            print_warning "Policy is still attached to roles: $ATTACHED"
            print_warning "Skipping policy deletion. Detach manually or delete role first."
        else
            print_info "Deleting IAM policy..."
            aws iam delete-policy --policy-arn "$POLICY_ARN"
            print_success "IAM policy deleted"
        fi
    else
        print_info "IAM policy not found (already removed)"
    fi
}

# Clean up downloaded files
cleanup_files() {
    print_header "Cleaning Up Downloaded Files"

    if [ -f "iam_policy.json" ]; then
        rm -f iam_policy.json
        print_info "Removed iam_policy.json"
    fi

    print_success "Cleanup complete"
}

# Verify cleanup
verify_cleanup() {
    print_header "Verifying Cleanup"

    print_info "Checking for remaining resources..."

    if kubectl get deployment aws-load-balancer-controller -n "$NAMESPACE" &>/dev/null; then
        print_warning "Controller deployment still exists!"
    else
        print_info "✓ Controller deployment removed"
    fi

    if kubectl get serviceaccount "$SERVICE_ACCOUNT_NAME" -n "$NAMESPACE" &>/dev/null; then
        print_warning "ServiceAccount still exists!"
    else
        print_info "✓ ServiceAccount removed"
    fi

    if kubectl get ingressclass alb &>/dev/null; then
        print_warning "IngressClass 'alb' still exists (may be used by other resources)"
    else
        print_info "✓ IngressClass removed"
    fi

    print_success "Verification complete"
}

# Main execution
main() {
    print_header "AWS Load Balancer Controller Cleanup"

    echo "This script will remove:"
    echo "  - Helm release (aws-load-balancer-controller)"
    echo "  - Kubernetes ServiceAccount"
    echo "  - IAM Role (created by IRSA)"
    echo "  - IAM Policy (AWSLoadBalancerControllerIAMPolicy)"
    echo ""
    read -p "Continue? (y/N) " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cleanup cancelled"
        exit 0
    fi

    get_info
    uninstall_helm
    delete_irsa
    delete_iam_policy
    cleanup_files
    verify_cleanup

    print_success "Cleanup completed!"
    
    cat << EOF

If you want to reinstall later, run:
  ./install-alb-controller.sh

EOF
}

# Run main function
main "$@"