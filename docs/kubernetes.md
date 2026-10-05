# Local Kubernetes

This real-AI recipe targets **macOS with Docker Desktop**, Kind, kubectl, OpenSSL, and the host Elixir/Codex setup from the [README](../README.md). The host gateway address is specific to Docker Desktop; native Linux requires a separately verified host networking setup. Use the native offline quick start for a portable first run.

For a fresh local Kind setup, install Kind and create a single-node cluster with a dedicated kubeconfig. These commands do not read or change the default kubeconfig. The deployment uses the host Codex gateway, so start it in a separate host terminal before applying the manifest. The gateway needs a local authenticated Codex CLI and a private token file:

```sh
mkdir -p -m 700 "$HOME/.config/rutvi-exercise"
if [ ! -f "$HOME/.config/rutvi-exercise/codex-gateway.token" ]; then
  (umask 077; openssl rand -hex 32 > "$HOME/.config/rutvi-exercise/codex-gateway.token")
fi
chmod 600 "$HOME/.config/rutvi-exercise/codex-gateway.token"
RUTVI_CODEX_GATEWAY_TOKEN_FILE="$HOME/.config/rutvi-exercise/codex-gateway.token" \
RUTVI_CODEX_GATEWAY_BIND=127.0.0.1 RUTVI_CODEX_GATEWAY_PORT=4041 \
MIX_ENV=dev mix run --no-start scripts/start-codex-gateway.exs
```

Leave that process running. In another terminal, create the cluster and apply the app. The apply script reads the gateway token and identities into Kubernetes Secrets without printing them or adding them to the image:

```sh
brew install kind kubectl
export KUBECONFIG="$HOME/.kube/config-rutvi-kind"
kind create cluster --name rutvi --kubeconfig "$KUBECONFIG"  # first run only
export KUBE_CONTEXT=kind-rutvi
HTTP_TOKEN=$(openssl rand -hex 24)
export HTTP_IDENTITIES="{\"$HTTP_TOKEN\":{\"namespace_id\":\"A\",\"user_id\":\"u1\",\"session_id\":\"s1\"}}"
unset HTTP_TOKEN
mkdir -p -m 700 "$HOME/.config/rutvi-exercise"
if [ ! -f "$HOME/.config/rutvi-exercise/kind-studio-secret" ]; then
  (umask 077; openssl rand -base64 72 > "$HOME/.config/rutvi-exercise/kind-studio-secret")
fi
chmod 600 "$HOME/.config/rutvi-exercise/kind-studio-secret"
scripts/k8s-image.sh       # builds and loads rutvi-exercise:local
scripts/k8s-apply.sh       # creates namespace, auth Secret, PVC, Deployment and Service
kubectl --context "$KUBE_CONTEXT" -n rutvi-exercise rollout status deployment/rutvi-exercise --timeout=180s
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" -n rutvi-exercise port-forward --address 127.0.0.1 service/rutvi-exercise 4018:4000
```

When finished, stop port-forward with Ctrl+C, then run `scripts/k8s-down.sh`. This stops the workload: it preserves the namespace, Secrets, and SQLite PVC. To remove all app data and credentials, first stop the port-forward, then explicitly delete the namespace with the same `--kubeconfig` and `--context`; this deletes the PVC:

```sh
kubectl --kubeconfig "$KUBECONFIG" --context "$KUBE_CONTEXT" delete namespace rutvi-exercise
```

To retire the local cluster too, run `kind delete cluster --name rutvi`. Keep the host gateway process separate; stop only the terminal that started it.

Every Kubernetes script requires `KUBE_CONTEXT` explicitly, accepts only a local `kind-*`, `k3d-*`, or `minikube` context, and rejects the known `engeto-prod-v2` context. The scripts never rely on kubectl's current/default context. The local Kind demo is served at `http://127.0.0.1:4018/`; its browser Studio, health probes, signed session, real-Luna course, checkpoint resume, and JSON download were verified. It reaches the host gateway at `127.0.0.1:4041` through Docker Desktop's `host.docker.internal`; the gateway binds only to host loopback and needs its own authenticated Codex CLI. The local test token map, stable Studio secret, and gateway token are private files under `$HOME/.config/rutvi-exercise/` with mode `0600`; values are not included here. Use your own files outside source control on another machine. See [acceptance status](acceptance.md) for exact evidence and the BEAM open-file-limit wrapper.
