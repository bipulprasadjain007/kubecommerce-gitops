#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bootstrap Argo CD on a local kind cluster (guide Phase 8, Step 8.1).
#
# Installs Argo CD from the argo-helm chart using bootstrap/argocd/values.yaml
# (local-only: single replica, server.insecure, no Dex/notifications).
#
# Usage:
#   ./install.sh                  # install Argo CD only
#   ./install.sh --with-root-app  # also apply argocd/root-app.yaml (app-of-apps)
#
# Prereqs: helm + kubectl on PATH and a reachable cluster (kind). This script
# does NOT create the cluster or the namespaces; see README.md for the full
# bootstrap sequence.
# ---------------------------------------------------------------------------
set -euo pipefail

# --- pinned versions --------------------------------------------------------
# Verified 2026-09-26 via `helm search repo argo/argo-cd --versions`:
#   argo/argo-cd 10.9.2  -> Argo CD app v3.5.3
# Bump this deliberately and re-run that command; a changed pin that has not
# been re-verified against the repo should be marked unverified in review.
ARGOCD_CHART_VERSION="10.9.2"
ARGOCD_REPO_NAME="argo"
ARGOCD_REPO_URL="https://argoproj.github.io/argo-helm"
ARGOCD_NAMESPACE="argocd"
# ---------------------------------------------------------------------------

WITH_ROOT_APP=false

usage() {
  cat <<'EOF'
Usage: install.sh [--with-root-app]

Installs/upgrades Argo CD into the current cluster using
bootstrap/argocd/values.yaml.

  --with-root-app   After install, apply argocd/root-app.yaml so Argo CD
                    reconciles argocd/ (AppProject + ApplicationSet).
EOF
}

for arg in "$@"; do
  case "$arg" in
    --with-root-app) WITH_ROOT_APP=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

echo "==> Preflight"
for bin in helm kubectl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "ERROR: '$bin' not found on PATH." >&2
    echo "       Try: export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2
    exit 1
  fi
done

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "ERROR: kubectl cannot reach a cluster. Create the kind cluster first." >&2
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="$SCRIPT_DIR/values.yaml"
ROOT_APP_FILE="$SCRIPT_DIR/../../argocd/root-app.yaml"

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "ERROR: values file not found: $VALUES_FILE" >&2
  exit 1
fi

echo "==> Adding/updating Helm repo '$ARGOCD_REPO_NAME'"
helm repo add "$ARGOCD_REPO_NAME" "$ARGOCD_REPO_URL" --force-update
helm repo update "$ARGOCD_REPO_NAME"

echo "==> Installing Argo CD $ARGOCD_CHART_VERSION (namespace: $ARGOCD_NAMESPACE)"
helm upgrade --install argocd "$ARGOCD_REPO_NAME/argo-cd" \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace "$ARGOCD_NAMESPACE" \
  --create-namespace \
  -f "$VALUES_FILE" \
  --wait

if [[ "$WITH_ROOT_APP" == "true" ]]; then
  if [[ ! -f "$ROOT_APP_FILE" ]]; then
    echo "ERROR: root app manifest not found: $ROOT_APP_FILE" >&2
    exit 1
  fi
  echo "==> Applying app-of-apps root Application"
  kubectl apply -n "$ARGOCD_NAMESPACE" -f "$ROOT_APP_FILE"
fi

cat <<EOF

=====================================================================
Argo CD is installed in namespace '$ARGOCD_NAMESPACE'.

Admin credentials:
  username: admin
  password: kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret \\
              -o jsonpath='{.data.password}' | base64 -d; echo

Open the UI (plain HTTP; server.insecure=true):
  kubectl -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8080:80
  # then browse to http://localhost:8080
  # CLI login: argocd login localhost:8080 --plaintext --username admin

Reminder: the environment namespaces are applied by the root app itself
(platform-namespaces child Application, sync-wave -5). If you installed Argo CD
without --with-root-app, apply them manually:
  kubectl apply -f "$SCRIPT_DIR/../../platform/namespaces/namespaces.yaml"

If you used --with-root-app, replace the repoURL placeholder in
argocd/root-app.yaml, argocd/applicationset.yaml and argocd/project.yaml
with your real repository URL first (see README.md).
=====================================================================
EOF
