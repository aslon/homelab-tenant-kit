#!/usr/bin/env bash
# Crée le cluster k3d jetable de la CI des équipes (ADR-051, point 4) : k3s à la version des clusters du homelab,
# image par digest, StorageClass local-path, CRD SealedSecret. Écrit son kubeconfig dans <fichier>.
# Usage : cluster.sh <kubeconfig> <crd-sealedsecret.yaml>
set -euo pipefail
KCFG="${1:?usage: cluster.sh <kubeconfig> <crd-sealedsecret.yaml>}"
CRD="${2:?usage: cluster.sh <kubeconfig> <crd-sealedsecret.yaml>}"
# Version de regles/SOURCE (k3s=v1.37.1+k3s1) ; tests/gitops/tenant-kit.sh vérifie l'accord des deux.
K3S_IMAGE="rancher/k3s:v1.37.1-k3s1@sha256:ca7f37d993d82ef0dcdcfecb2e0e2618ea541dbaffc620c8cedebe01a82acd0d"

echo "[1/3] k3d ($K3S_IMAGE)"
k3d cluster create kit --image "$K3S_IMAGE" --servers 1 --agents 0 --no-lb --wait --timeout 180s \
  --k3s-arg '--disable=traefik,metrics-server@server:0' --kubeconfig-update-default=false >/dev/null
k3d kubeconfig get kit >"$KCFG"
export KUBECONFIG="$KCFG"
echo "[2/3] CRD SealedSecret"
kubectl apply --server-side -f "$CRD" >/dev/null
kubectl wait --for=condition=Established crd/sealedsecrets.bitnami.com --timeout=60s >/dev/null
echo "[3/3] API prête"
for _ in $(seq 1 30); do kubectl get serviceaccount default -n default >/dev/null 2>&1 && break; sleep 2; done
kubectl get nodes -o name
