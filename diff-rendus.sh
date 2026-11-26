#!/usr/bin/env bash
# Différence des rendus de chaque deploy/<app>/{dev,prod} entre la branche cible et la PR (ADR-051, point 5), en
# Markdown, pour le résumé du job : une PR qui touche base/ montre ses deux rendus. N'échoue jamais sur un rendu cassé
# (verifier.sh le refuse déjà) ; tronqué au-delà de 60 000 caractères.
# Usage : diff-rendus.sh <dépôt git> <ref de la branche cible>
set -euo pipefail
DEPOT="$(cd "${1:?usage: diff-rendus.sh <dépôt> <ref cible>}" && pwd -P)" # -P : comme git, liens résolus
BASE="${2:?usage: diff-rendus.sh <dépôt> <ref cible>}"
racine="$(git -C "$DEPOT" rev-parse --show-toplevel)"
rel="${DEPOT#"$racine"}"; rel="${rel#/}"
tmp="$(mktemp -d)"
trap 'git -C "$racine" worktree remove --force "$tmp/base" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
git -C "$racine" worktree add --detach "$tmp/base" "$BASE" >/dev/null 2>&1 || { echo "branche cible $BASE introuvable : pas de différence"; exit 0; }
cible="$tmp/base${rel:+/$rel}"

rendre() { [ -d "$1" ] && kubectl kustomize "$1" 2>&1 || true; }
apps="$( { ls "$DEPOT/deploy" 2>/dev/null || true; ls "$cible/deploy" 2>/dev/null || true; } | sort -u)"
out="$tmp/resume.md"
echo "## Rendus modifiés par la PR (base : $BASE)" >"$out"
n=0
for app in $apps; do
  for env in dev prod; do
    [ -d "$DEPOT/deploy/$app/$env" ] || [ -d "$cible/deploy/$app/$env" ] || continue
    if ! d="$(diff -u --label "$BASE" --label "PR" <(rendre "$cible/deploy/$app/$env") <(rendre "$DEPOT/deploy/$app/$env"))"; then
      printf '\n### %s/%s\n\n```diff\n%s\n```\n' "$app" "$env" "$d" >>"$out"; n=$((n + 1))
    fi
  done
done
[ "$n" -gt 0 ] || echo "Aucun rendu modifié." >>"$out"
if [ "$(wc -c <"$out")" -gt 60000 ]; then head -c 60000 "$out"; printf '\n```\n\n(tronqué)\n'; else cat "$out"; fi
