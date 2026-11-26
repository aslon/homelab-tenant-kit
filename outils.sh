#!/usr/bin/env bash
# Télécharge les outils de la CI des équipes (ADR-051, point 6) dans <dossier>, linux-amd64, version et sha256
# épinglées : un fichier dont l'empreinte diffère arrête tout. Aucune action tierce, aucun cache.
# Usage : outils.sh <dossier>     (le workflow ajoute <dossier> au PATH)
# Les versions suivent les clusters du homelab : tests/gitops/tenant-kit.sh vérifie k3s et Sealed Secrets contre
# regles/SOURCE.
set -euo pipefail
DEST="${1:?usage: outils.sh <dossier>}"

KUBECTL_VERSION=v1.37.1
KUBECTL_SHA256=65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
K3D_VERSION=v5.9.0
K3D_SHA256=06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0
KUBECONFORM_VERSION=v0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
YQ_VERSION=v4.52.4
YQ_SHA256=0c4d965ea944b64b8fddaf7f27779ee3034e5693263786506ccd1c120f184e8c
# CRD SealedSecret du chart sealed-secrets épinglé dans le homelab (gitops/clusters/<env>/sealed-secrets/version.yaml).
SEALED_SECRETS_CHART=2.22.0
SEALED_SECRETS_CRD_SHA256=6ccc74ae40a65ec4a1ab95baaf34b0beef0591d343fe3aea1104a36a4f283fab # gitleaks:allow (empreinte publique)

# telecharger <url> <sha256> <fichier>
telecharger() {
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet - || { echo "empreinte inattendue : $1" >&2; rm -f "$3"; exit 1; }
}

mkdir -p "$DEST"
echo "[1/5] kubectl $KUBECTL_VERSION"
telecharger "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl" "$KUBECTL_SHA256" "$DEST/kubectl"
echo "[2/5] k3d $K3D_VERSION"
telecharger "https://github.com/k3d-io/k3d/releases/download/$K3D_VERSION/k3d-linux-amd64" "$K3D_SHA256" "$DEST/k3d"
echo "[3/5] kubeconform $KUBECONFORM_VERSION"
telecharger "https://github.com/yannh/kubeconform/releases/download/$KUBECONFORM_VERSION/kubeconform-linux-amd64.tar.gz" \
  "$KUBECONFORM_SHA256" "$DEST/kubeconform.tar.gz"
tar -xzf "$DEST/kubeconform.tar.gz" -C "$DEST" kubeconform && rm -f "$DEST/kubeconform.tar.gz"
echo "[4/5] yq $YQ_VERSION"
telecharger "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_amd64" "$YQ_SHA256" "$DEST/yq"
echo "[5/5] CRD SealedSecret (chart $SEALED_SECRETS_CHART)"
telecharger "https://raw.githubusercontent.com/bitnami-labs/sealed-secrets/helm-v$SEALED_SECRETS_CHART/helm/sealed-secrets/crds/bitnami.com_sealedsecrets.yaml" \
  "$SEALED_SECRETS_CRD_SHA256" "$DEST/sealedsecret-crd.yaml"
chmod +x "$DEST/kubectl" "$DEST/k3d" "$DEST/kubeconform" "$DEST/yq"
