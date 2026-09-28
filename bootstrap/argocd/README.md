# Argo CD bootstrap (local kind cluster)

GitOps bootstrap for KubeCommerce (guide Phase 8). Argo CD installs once from
Helm; from then on, desired state is reconciled from this repository.

## 1. Replace the repository URL placeholders

The manifests use the obvious placeholder
`https://github.com/your-github-username/kubecommerce-gitops.git`. Replace it in
**all three** Argo CD manifests before syncing:

```bash
export PATH="$HOME/.local/bin:$PATH"
cd kubecommerce-gitops

GITOPS_REPO_URL="https://github.com/<your-github-username>/kubecommerce-gitops.git"

sed -i "s#https://github.com/your-github-username/kubecommerce-gitops.git#${GITOPS_REPO_URL}#g" \
  argocd/project.yaml \
  argocd/applicationset.yaml \
  argocd/root-app.yaml

grep -rn "your-github-username" argocd/   # must print nothing
```

## 2. Fresh kind cluster sequence

Assumes lane D1's `scripts/kind-up.sh` exists in repo A and that `kubectl`,
`helm` and `kind` are on `PATH`.

```bash
export PATH="$HOME/.local/bin:$PATH"

# 2.1 Create the cluster (Gateway API CRDs, Envoy Gateway, metrics-server,
#     and the namespaces are installed by the kind bootstrap).
#     From repo A:
#       ./scripts/kind-up.sh

# 2.2 Apply the platform namespaces (idempotent; must exist before the
#     ApplicationSet syncs, because the Applications use CreateNamespace=false).
kubectl apply -f kubecommerce-gitops/platform/namespaces/namespaces.yaml

# 2.3 Apply the north-south routing (GatewayClass + Gateway + HTTPRoutes).
kubectl apply -f kubecommerce-gitops/platform/gateway/

# 2.4 Install Argo CD (Helm, pinned chart) into the `argocd` namespace.
kubecommerce-gitops/bootstrap/argocd/install.sh

# 2.5 Bootstrap the app-of-apps: applies argocd/root-app.yaml. Argo CD then
#     creates the `kubecommerce` AppProject + the ApplicationSet, which
#     materialises the dev/staging/prod Applications.
kubecommerce-gitops/bootstrap/argocd/install.sh --with-root-app
```

Access the UI:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

kubectl -n argocd port-forward svc/argocd-server 8080:80
# browse http://localhost:8080  (user: admin, password above)
```

Routing check (kind maps host port 80 to Envoy):

```bash
curl -i http://localhost/api/catalog/products   # -> gateway-api
# optional friendly name:
#   echo "127.0.0.1 kubecommerce.local" | sudo tee -a /etc/hosts
#   and uncomment `hostname:` in platform/gateway/gateway.yaml +
#   `hostnames:` in platform/gateway/httproute.yaml, then re-apply.
```

## 3. Private repository credentials

If the GitOps repository is private, Argo CD cannot clone it anonymously. Create
a repository secret in the `argocd` namespace (replace the placeholders; use a
fine-grained PAT with read-only `contents` scope, never a password):

```bash
kubectl -n argocd create secret generic kubecommerce-gitops-repo \
  --from-literal=type=git \
  --from-literal=url="https://github.com/<your-github-username>/kubecommerce-gitops.git" \
  --from-literal=username="<github-username>" \
  --from-literal=password="<github-pat>"

kubectl -n argocd label secret kubecommerce-gitops-repo \
  argocd.argoproj.io/secret-type=repository
```

For a public repository this step is unnecessary. For SSH instead of HTTPS,
use `type=git`, `url=git@github.com:...` and an `sshPrivateKey` key instead of
`password`.

## 4. What gets created

| Path | Purpose |
|---|---|
| `argocd/project.yaml` | AppProject `kubecommerce`: source repo, destination namespaces, minimal resource allow-list. |
| `argocd/applicationset.yaml` | One Application per env (`dev`/`staging`/`prod`) rendering `charts/kubecommerce` with `environments/<env>/values.yaml`. |
| `argocd/root-app.yaml` | App-of-apps Application that reconciles `argocd/` (project + ApplicationSet). Uses `project: default` because it must create the restricted project. |

Sync policy per environment (see `templatePatch` in `applicationset.yaml`):

| Env | Automated | prune | selfHeal |
|---|---|---|---|
| dev | yes | yes | yes |
| staging | yes | yes | no |
| prod | **no** (manual, approval-gated) | n/a | n/a |

## 5. Self-healing demo (guide Phase 8.6)

Only `dev` has `selfHeal: true`, so use the dev Application.

```bash
# 1. Confirm the Git-declared replica count (success)
kubectl -n kubecommerce-dev get deployment gateway-api

# 2. Manually drift the live state away from Git
kubectl -n kubecommerce-dev scale deployment/gateway-api --replicas=5

# 3. Watch Argo CD report OutOfSync (UI shows it within ~seconds)
kubectl -n argocd port-forward svc/argocd-server 8080:80 &
#   UI: Applications -> kubecommerce-dev -> "OutOfSync"
#   or: argocd app get kubecommerce-dev --plaintext --port-forward-namespace argocd

# 4. Watch Argo CD reconcile back to the Git-declared value (selfHeal)
kubectl -n kubecommerce-dev get deployment gateway-api -w
#   within the reconciliation interval the replica count returns to Git's value.
```

Contrast with `staging` (automated prune, **no** selfHeal) and `prod` (manual):
manual drift there stays `OutOfSync` until a Git change (staging) or an explicit
sync (prod). This models "self-heal in dev only, audited manual promotion for
production".
