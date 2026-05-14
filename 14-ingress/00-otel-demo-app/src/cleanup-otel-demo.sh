#!/bin/bash

# OpenTelemetry Demo Cleanup Script
# Removes the OTel Demo application from the cluster

set -e

# Configuration
NAMESPACE="${1:-otel-demo}"
RELEASE_NAME="${2:-otel-demo}"

echo "Cleaning up OpenTelemetry Demo..."
echo ""

# Uninstall Helm release
echo "Uninstalling Helm release: $RELEASE_NAME"
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE"

echo ""
echo "Deleting namespace: $NAMESPACE"
kubectl delete namespace "$NAMESPACE"

echo ""
echo "Cleanup complete!"
echo "To redeploy, run: ./install-otel-demo.sh"