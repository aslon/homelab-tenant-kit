# homelab-tenant-kit

CI des équipes qui déploient sur les clusters du homelab : chaque PR de votre dépôt de déploiement est vérifiée contre
les **règles réelles** des clusters (admission, Pod Security restricted, quotas, types autorisés), rejouées dans un
cluster k3d jetable. Rien n'est déployé, aucun secret n'est demandé.

Ce dépôt est **généré** depuis le dépôt homelab (privé) : n'y proposez pas de modification, signalez plutôt un faux
verdict à l'admin.

## Brancher la CI

Dans votre dépôt de déploiement, `.github/workflows/homelab.yml` :

```yaml
name: homelab
on: pull_request
permissions:
  contents: read
jobs:
  homelab:
    uses: aslon/homelab-tenant-kit/.github/workflows/verifier.yml@<sha du dernier tag vX.Y.Z>
    with:
      team: <votre équipe>
      version-kit: <le même sha>
```

- **Épinglez par SHA** (Renovate ou Dependabot le mettent à jour) ; `@v1` avec `version-kit` par défaut est le
  confort, au prix de suivre le kit sans relecture.
- `permissions: contents: read` chez vous : le kit ne reçoit jamais de droit d'écriture.
- Les règles, elles, sont toujours lues au tag `regles-courantes` : un workflow épinglé ne valide pas contre des règles
  périmées.

## Ce qui est vérifié

Pour chaque `deploy/<app>/dev` et `deploy/<app>/prod` :

1. rendu kustomize, sans helm, exec ni plugins (comme Argo CD) ;
2. schémas (kubeconform), types autorisés, namespace `<équipe>-<app>`, LimitRange par pod et somme face au quota ;
3. admission à blanc dans le cluster jetable (`--dry-run=server --warnings-as-errors`) : un refus affiche le message
   exact du cluster ;
4. image sans digest : avertissement ;
5. sur une PR, la différence des rendus avec la branche cible, dans le résumé du job.

## Ce que la CI ne garantit pas

**CI verte ne veut pas dire admis.** Les barrières restent celles du cluster. Hors de portée :

- la compatibilité gVisor de votre image (appels système) ;
- le déchiffrement de vos SealedSecret ;
- les écarts accordés à votre équipe (exposition partielle, quota surchargé) : la CI suppose les valeurs par défaut,
  une app par dossier exposée en `<app>-dev.alson-lab.fr` et `<app>.alson-lab.fr`.

## Lancer à la main

`verifier.sh --team <équipe> --depot <dossier> [--installer-regles]` contre un cluster de test (`KUBECONFIG`) ;
`outils.sh` et `cluster.sh` montent le même cluster k3d que la CI (linux-amd64).
