#!/bin/sh
set -eu

: "${KUBE_CONTEXT:?Set KUBE_CONTEXT to an explicitly named local cluster context}"

case "$KUBE_CONTEXT" in
  engeto-prod-v2)
    echo "Refusing the known production context: $KUBE_CONTEXT" >&2
    exit 2
    ;;
  kind-*|k3d-*|minikube)
    ;;
  *)
    echo "Refusing unrecognized context '$KUBE_CONTEXT'; use kind-*, k3d-*, or minikube" >&2
    exit 2
    ;;
esac

if ! kubectl config get-contexts -o name | grep -Fxq "$KUBE_CONTEXT"; then
  echo "KUBE_CONTEXT is not present in the local kubeconfig: $KUBE_CONTEXT" >&2
  exit 2
fi
