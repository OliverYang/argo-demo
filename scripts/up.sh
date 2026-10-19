#!/usr/bin/env bash
# Bring the whole local stack back up after a reboot.
# Everything here is idempotent: safe to run twice.
set -euo pipefail
cd "$(dirname "$0")/.."
K=/opt/homebrew/bin

echo "==> 1/4 Colima"
if ! $K/docker info >/dev/null 2>&1; then
  # --dns is mandatory on this machine: the VM image has no systemd-resolved,
  # so without explicit DNS every registry pull fails with a [::1]:53 refused.
  $K/colima start --cpu 4 --memory 6 --disk 60 \
    --vm-type vz --mount-type virtiofs \
    --dns 114.114.114.114 --dns 223.5.5.5
fi

echo "==> 2/4 registry mirrors (needed: Docker Hub is unreachable here)"
if ! $K/docker info 2>/dev/null | grep -q "docker.m.daocloud.io"; then
  $K/colima ssh -- sh -c 'sudo python3 - <<EOF
import json
p="/etc/docker/daemon.json"
d=json.load(open(p))
d["registry-mirrors"]=["https://docker.m.daocloud.io","https://docker.1ms.run","https://dockerproxy.net"]
json.dump(d,open(p,"w"),indent=2)
EOF
sudo systemctl restart docker'
  sleep 3
fi

echo "==> 3/4 kind cluster"
if ! $K/kubectl config current-context 2>/dev/null | grep -q kind-argo-demo; then
  $K/kind create cluster --name argo-demo --wait 120s
fi

echo "==> 4/4 Argo CD"
# `create ... --dry-run | apply` is the idempotent form. A bare `create ns`
# exits non-zero when it already exists, and under `set -e` that aborts the run.
# --server-side avoids client-side openapi validation, which fails outright
# when the API server is briefly unreachable on this network.
$K/kubectl create namespace argocd --dry-run=client -o yaml | $K/kubectl apply --server-side -f -
if ! $K/kubectl -n argocd get deploy argocd-server >/dev/null 2>&1; then
  $K/kubectl apply -n argocd --server-side --force-conflicts \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  # Default Service maps 443 -> 8443 (TLS terminated inside the pod).
  # We serve plain HTTP on 8080, so point 443 at it for port-forward.
fi
$K/kubectl -n argocd patch svc argocd-server --type merge -p \
  '{"spec":{"ports":[{"name":"https","port":443,"protocol":"TCP","targetPort":8080}]}}' >/dev/null
$K/kubectl -n argocd wait --for=condition=Ready pods --all --timeout=300s >/dev/null

echo "==> pin github.com for argocd-repo-server"
# Local network resolves github.com to an IP that is unreachable; this keeps
# Argo CD's git fetch from timing out. See ENVIRONMENT.md "坑 4".
$K/kubectl -n argocd patch deploy argocd-repo-server --type json -p \
  '[{"op":"replace","path":"/spec/template/spec/hostAliases",
    "value":[{"ip":"140.82.112.3","hostnames":["github.com"]}]}]' >/dev/null 2>&1 || true

echo
echo "Done. Next:"
echo "  scripts/port-forward.sh   # expose Argo CD UI + the app"
echo "  open https://localhost:8080   (admin / see .argocd-password)"
