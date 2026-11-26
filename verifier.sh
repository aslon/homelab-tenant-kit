#!/usr/bin/env bash
# Vérifie le dépôt de déploiement d'une équipe contre les règles réelles du homelab (ADR-051), sans rien déployer.
# Appelé par le workflow réutilisable du kit dans un cluster k3d jetable ; lançable aussi à la main contre un cluster
# de test (chemin de dépannage). Une CI verte ne garantit pas l'admission : gVisor, déchiffrement des SealedSecret et
# écarts aux valeurs par défaut de l'équipe restent hors de portée (ADR-051, point 9).
#
# Usage : verifier.sh --team <équipe> [--depot <dossier>] [--regles <dossier>] [--installer-regles]
#   --depot             racine du dépôt de déploiement (défaut : dossier courant), apps sous deploy/<app>/{dev,prod}
#   --regles            dossier des règles (défaut : regles/ à côté du script ; la CI lit le tag regles-courantes)
#   --installer-regles  pose regles/admission.yaml dans le cluster (cluster jetable seulement)
# kubeconform, s'il est dans le PATH, pré-filtre les schémas à la version de k3s de regles/SOURCE.
# KUBECONFIG désigne le cluster. Un namespace <équipe>-<app> déjà présent et étiqueté pour l'équipe est utilisé tel
# quel ; sinon le socle par défaut (regles/socle-<env>.yaml) est créé, puis supprimé à la fin. Rien d'autre n'est
# écrit : tout le reste passe en --dry-run=server.
# Sortie : « OK <app>/<env> », « REFUS <app>/<env> : <message> », « AVERTISSEMENT … », puis
# « Verdict: X accepté(s), Y refusé(s) » ; code 1 s'il y a un refus.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGLES="$KIT/regles"
TEAM=""; DEPOT="$PWD"; INSTALLER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --team) TEAM="${2:-}"; shift 2 ;;
    --depot) DEPOT="${2:-}"; shift 2 ;;
    --regles) REGLES="${2:-}"; shift 2 ;;
    --installer-regles) INSTALLER=1; shift ;;
    *) echo "usage: $0 --team <équipe> [--depot <dossier>] [--regles <dossier>] [--installer-regles]" >&2; exit 2 ;;
  esac
done
[[ "$TEAM" =~ ^[a-z0-9]+$ ]] || { echo "--team : minuscules et chiffres, sans tiret (reçu « $TEAM »)" >&2; exit 2; }
[ -d "$DEPOT/deploy" ] || { echo "$DEPOT/deploy introuvable : apps attendues sous deploy/<app>/{dev,prod}" >&2; exit 2; }
for c in kubectl yq python3; do command -v "$c" >/dev/null || { echo "$c introuvable" >&2; exit 2; }; done
[ -n "${KUBECONFIG:-}" ] || { echo "KUBECONFIG requis : le cluster de vérification" >&2; exit 2; }
for f in admission.yaml socle-dev.yaml socle-prod.yaml types.txt; do
  [ -s "$REGLES/$f" ] || { echo "$REGLES/$f absent : kit incomplet" >&2; exit 2; }
done

tmp="$(mktemp -d)"; crees=()
nettoyer() {
  local ns
  for ns in "${crees[@]+"${crees[@]}"}"; do kubectl delete namespace "$ns" --wait=false >/dev/null 2>&1 || true; done
  rm -rf "$tmp"
}
trap nettoyer EXIT
acceptes=0; refuses=0
refus() { echo "REFUS $1 : $2"; refuses=$((refuses + 1)); }

echo "[1/5] Rendu des apps"
cibles=()
for d in "$DEPOT"/deploy/*/; do
  app="$(basename "$d")"
  [[ "$app" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { refus "$app" "nom d'app invalide (minuscules, chiffres, tirets)"; continue; }
  for env in dev prod; do
    [ -d "$d$env" ] || continue
    # Ni --enable-helm, ni --enable-exec, ni plugins : comme le repo-server d'Argo CD.
    if out="$(kubectl kustomize "$d$env" 2>&1)"; then
      printf '%s\n' "$out" >"$tmp/$app-$env.yaml"; cibles+=("$app/$env")
    else
      refus "$app/$env" "ne se rend pas : $(tail -1 <<<"$out")"
    fi
  done
done
[ "${#cibles[@]}" -gt 0 ] || [ "$refuses" -gt 0 ] || { echo "aucune app sous $DEPOT/deploy/<app>/{dev,prod}" >&2; exit 2; }

echo "[2/5] Contrôles statiques (schémas, types, namespace, quotas, images)"
statique_ko=" " # « app/env » refusés au contrôle statique (bash 3.2 : pas de tableau associatif)
k8s="$(sed -n 's/^k3s=v\([0-9.]*\)+.*/\1/p' "$REGLES/SOURCE" 2>/dev/null || true)"
for c in "${cibles[@]+"${cibles[@]}"}"; do
  app="${c%/*}"; env="${c#*/}"; f="$tmp/$app-$env.yaml"; ns="$TEAM-$app"; msgs=()
  # Pré-filtre de schémas (ADR-021) ; les CRD (SealedSecret) sont validées ensuite par le cluster.
  if command -v kubeconform >/dev/null && [ -n "$k8s" ]; then
    while IFS= read -r m; do [ -n "$m" ] && msgs+=("schéma : $m"); done < <(kubeconform -strict -ignore-missing-schemas \
      -kubernetes-version "$k8s" -output text "$f" 2>&1 | grep -vE '^Summary:' | sed -E 's#^[^ ]+ - ##' || true)
  fi
  while IFS='|' read -r av kind nsobj; do
    [ -n "$kind" ] || continue
    grp=""; [[ "$av" == */* ]] && grp="${av%/*}"
    grep -qx "$grp/$kind" "$REGLES/types.txt" || msgs+=("type $grp/$kind non admis (liste blanche de l'AppProject)")
    [ -z "$nsobj" ] || [ "$nsobj" = "$ns" ] || msgs+=("$kind dans le namespace $nsobj au lieu de $ns")
  done < <(yq -N '[.apiVersion // "", .kind // "", .metadata.namespace // ""] | join("|")' "$f")
  while IFS= read -r img; do
    [ -n "$img" ] && [[ "$img" != *@sha256:* ]] && echo "AVERTISSEMENT $c : image sans digest ($img), obligatoire à l'ADR-050"
  done < <(yq -N '.. | select(has("image")) | .image' "$f" 2>/dev/null | sort -u)
  # Ce qu'un dry-run ne voit pas : LimitRange par pod et quota du namespace, jamais évalués sans pod créé.
  quotas="$(yq -o=json -I=0 'select(.kind == "ResourceQuota" and .metadata.name == "team-quota") | .spec.hard' "$REGLES/socle-$env.yaml")"
  maxpod="$(yq -o=json -I=0 'select(.kind == "LimitRange") | .spec.limits[] | select(.type == "Pod") | .max' "$REGLES/socle-$env.yaml")"
  # Une erreur du contrôle (rendu illisible, quantité invalide) est un refus, jamais un passage silencieux.
  if lim="$(yq -o=json -I=0 '.' "$f" | QUOTAS="$quotas" MAXPOD="$maxpod" python3 -I "$KIT/limites.py" 2>&1)"; then
    while IFS= read -r m; do [ -n "$m" ] && msgs+=("$m"); done <<<"$lim"
  else
    msgs+=("contrôle des quotas impossible : $(tail -1 <<<"$lim")")
  fi
  if [ "${#msgs[@]}" -gt 0 ]; then
    # Un message par cause, avec le nombre d'objets concernés.
    while IFS= read -r m; do refus "$c" "$m"; done < <(printf '%s\n' "${msgs[@]}" | sort | uniq -c | sed -E 's/^ *1 //; s/^ *([0-9]+) (.*)$/\2 (×\1)/')
    statique_ko+="$c "
  fi
done

echo "[3/5] Règles d'admission"
if [ "$INSTALLER" = 1 ]; then
  kubectl apply --server-side -f "$REGLES/admission.yaml" >/dev/null
  # Une VAP n'agit qu'une fois son binding pris en compte : attendre que les deux soient servis.
  sleep 5
fi
n="$(kubectl get validatingadmissionpolicies -o name 2>/dev/null | grep -c '/tenant-' || true)"
[ "$n" -gt 0 ] || { echo "aucune règle tenant-* dans le cluster : --installer-regles sur un cluster jetable" >&2; exit 2; }

echo "[4/5] Socle des namespaces"
# socle <app> <env> : crée ou met à jour le socle d'un namespace créé ici ; jamais un namespace existant.
socle() {
  local app="$1" env="$2" ns="$TEAM-$1" equipe
  # Namespace en cours de suppression (lancement précédent) : attendre qu'il disparaisse.
  for _ in $(seq 1 60); do
    [ "$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = Terminating ] || break; sleep 1
  done
  if [[ " ${crees[*]+"${crees[*]}"} " == *" $ns "* ]] || ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    sed -e "s/__TEAM__/$TEAM/g" -e "s/__APP__/$app/g" "$REGLES/socle-$env.yaml" | kubectl apply -f - >/dev/null
    [[ " ${crees[*]+"${crees[*]}"} " == *" $ns "* ]] || crees+=("$ns")
    # Un quota tout juste créé n'a pas de statut : l'admission refuserait tout (« status unknown for quota »).
    local h=""
    for _ in $(seq 1 30); do
      h="$(kubectl get resourcequota team-quota -n "$ns" -o jsonpath='{.status.hard}' 2>/dev/null || true)"
      [ -n "$h" ] && break; sleep 1
    done
    [ -n "$h" ] || { echo "quota du namespace $ns sans statut après 30 s"; return 1; }
    return 0
  fi
  equipe="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.team}')"
  [ "$equipe" = "$TEAM" ] || { echo "namespace $ns existant, d'une autre équipe ($equipe)"; return 1; }
}

echo "[5/5] Admission à blanc (--dry-run=server --warnings-as-errors)"
for c in "${cibles[@]+"${cibles[@]}"}"; do
  [[ "$statique_ko" != *" $c "* ]] || continue
  app="${c%/*}"; env="${c#*/}"
  # Pas de $(…) : socle complète la liste des namespaces créés, qui doit rester dans ce shell pour le nettoyage.
  if ! socle "$app" "$env" >"$tmp/socle.out" 2>&1; then refus "$c" "$(tail -1 "$tmp/socle.out")"; continue; fi
  if out="$(kubectl apply --dry-run=server --warnings-as-errors -n "$TEAM-$app" -f "$tmp/$app-$env.yaml" 2>&1)"; then
    echo "OK $c"; acceptes=$((acceptes + 1))
  else
    while IFS= read -r l; do [ -n "$l" ] && refus "$c" "$l"; done < <(grep -E 'Error|error|Warning|denied|forbidden|violates' <<<"$out" | grep -vE '^error: [0-9]+ warnings? received$' || tail -1 <<<"$out")
  fi
done

echo "Verdict: $acceptes accepté(s), $refuses refusé(s)"
[ "$refuses" -eq 0 ]
