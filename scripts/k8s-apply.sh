#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/k8s-context.sh"
: "${HTTP_IDENTITIES:?Set HTTP_IDENTITIES to the JSON bearer-token map before applying}"
studio_secret_file=${RUTVI_STUDIO_SECRET_FILE:-"$HOME/.config/rutvi-exercise/kind-studio-secret"}
gateway_token_file=${RUTVI_CODEX_GATEWAY_TOKEN_FILE:-"$HOME/.config/rutvi-exercise/codex-gateway.token"}
[ -f "$studio_secret_file" ] || {
  echo "Studio secret file is missing: $studio_secret_file" >&2
  exit 2
}
[ -f "$gateway_token_file" ] || {
  echo "Local Codex gateway token file is missing: $gateway_token_file" >&2
  exit 2
}

kubectl --context "$KUBE_CONTEXT" apply -f "$script_dir/../k8s/namespace.yaml"
secret_file=$(mktemp)
trap 'rm -f "$secret_file"' EXIT HUP INT TERM
chmod 600 "$secret_file"
printf '%s' "$HTTP_IDENTITIES" > "$secret_file"
kubectl --context "$KUBE_CONTEXT" -n rutvi-exercise create secret generic rutvi-http-auth \
  --from-file="HTTP_IDENTITIES=$secret_file" \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
kubectl --context "$KUBE_CONTEXT" -n rutvi-exercise create secret generic rutvi-studio-auth \
  --from-file="RUTVI_STUDIO_SECRET=$studio_secret_file" \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
kubectl --context "$KUBE_CONTEXT" -n rutvi-exercise create secret generic rutvi-codex-gateway \
  --from-file="RUTVI_CODEX_GATEWAY_TOKEN=$gateway_token_file" \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
kubectl --context "$KUBE_CONTEXT" apply -f "$script_dir/../k8s/runtime.yaml"
