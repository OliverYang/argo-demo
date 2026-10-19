#!/usr/bin/env bash
# Open local access to everything the demo needs. Run in its own terminal;
# it stays in the foreground so Ctrl-C closes all three tunnels at once.
set -uo pipefail

cleanup() { trap - INT TERM EXIT; pkill -P $$ 2>/dev/null; exit 0; }
trap cleanup INT TERM EXIT

echo "starting tunnels (Ctrl-C to stop all)..."

# Argo CD UI + CLI. Self-signed cert -> browser warning is expected;
# the CLI needs --insecure for the same reason.
kubectl -n argocd port-forward svc/argocd-server 8080:443 >/dev/null 2>&1 &

# The two environments, on separate ports so you can compare them side by side.
kubectl -n argo-demo-dev  port-forward svc/argo-demo 18090:80 >/dev/null 2>&1 &
kubectl -n argo-demo-prod port-forward svc/argo-demo 18091:80 >/dev/null 2>&1 &

sleep 4
cat <<'EOF'

  Argo CD UI   https://localhost:8080     admin / see .argocd-password
  argocd CLI   argocd app list --insecure --grpc-web
  DEV  app     http://localhost:18090/    (also /version, /healthz)
  PROD app     http://localhost:18091/

EOF

wait
