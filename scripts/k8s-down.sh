#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/k8s-context.sh"

# Keep the namespace, Secret, and PVC so a workload restart does not delete task data.
kubectl --context "$KUBE_CONTEXT" -n rutvi-exercise delete deployment rutvi-exercise --ignore-not-found
kubectl --context "$KUBE_CONTEXT" -n rutvi-exercise delete service rutvi-exercise --ignore-not-found
kubectl --context "$KUBE_CONTEXT" -n rutvi-exercise delete configmap rutvi-runtime --ignore-not-found
