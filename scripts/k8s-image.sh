#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/k8s-context.sh"

image=${IMAGE:-rutvi-exercise:local}
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
docker build -t "$image" "$repo_root"

case "$KUBE_CONTEXT" in
  kind-*)
    command -v kind >/dev/null 2>&1 || { echo "kind CLI is required to load this image" >&2; exit 2; }
    kind load docker-image --name "${KUBE_CONTEXT#kind-}" "$image"
    ;;
  k3d-*)
    command -v k3d >/dev/null 2>&1 || { echo "k3d CLI is required to load this image" >&2; exit 2; }
    k3d image import --cluster "${KUBE_CONTEXT#k3d-}" "$image"
    ;;
  minikube)
    command -v minikube >/dev/null 2>&1 || { echo "minikube CLI is required to load this image" >&2; exit 2; }
    minikube image load "$image"
    ;;
esac
