#!/usr/bin/env bash
# Le workflow de l'équipe appelle verifier.yml@<ref> et passe version-kit : les deux doivent désigner la même version,
# sinon la CI tourne avec les scripts d'une autre version que le workflow. Dependabot ne met à jour que la ref de
# uses: ; ce contrôle fait échouer sa PR tant que version-kit n'a pas été recopié.
# Usage : version-kit.sh <fichier du workflow appelant> <version-kit reçue>
# Sans appel de verifier.yml du kit dans le fichier (auto-test du kit, workflow local), rien à comparer : succès.
set -euo pipefail
WF="${1:?usage: version-kit.sh <workflow> <version-kit>}"
VK="${2:?usage: version-kit.sh <workflow> <version-kit>}"
[ -f "$WF" ] || { echo "workflow appelant introuvable : $WF" >&2; exit 1; }
refs="$(grep -oE 'aslon/homelab-tenant-kit/\.github/workflows/verifier\.yml@[^[:space:]#]+' "$WF" | sed 's/.*@//' | sort -u || true)"
[ -n "$refs" ] || { echo "OK version du kit : pas d'appel épinglé dans $WF"; exit 0; }
[ "$(wc -l <<<"$refs")" -eq 1 ] || { echo "REFUS version du kit : plusieurs versions de verifier.yml dans $WF" >&2; exit 1; }
if [ "$refs" != "$VK" ]; then
  echo "REFUS version du kit : uses: appelle verifier.yml@$refs mais version-kit vaut $VK." >&2
  echo "Mettez version-kit au même SHA que uses: (une PR Dependabot ne change que uses:)." >&2
  exit 1
fi
echo "OK version du kit : uses: et version-kit valent $VK"
