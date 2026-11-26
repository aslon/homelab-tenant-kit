# Référence (guide des équipes, niveau 3)

Ce que le homelab impose, ce qu'il fournit, ce qu'il ne garantit pas, et quoi faire d'un refus. Le parcours de
départ est le tutoriel du [modèle](https://github.com/aslon/homelab-tenant-template) ; le quotidien, l'[usage
courant](usage.md).

## Les règles

Chacune est vérifiée à l'entrée du cluster, et rejouée par la CI à chaque PR ; une ressource qui ne la respecte pas
est refusée avec le message cité.

| Règle | Message en cas de refus |
|---|---|
| `runtimeClassName: gvisor` sur chaque pod | `runtimeClassName doit valoir gvisor (ADR-021).` |
| Pas de root, pas d'élévation, `drop: [ALL]`, seccomp `RuntimeDefault` (Pod Security « restricted ») | `violates PodSecurity "restricted:latest"` |
| Limites `cpu`, `memory` et `ephemeral-storage` sur chaque conteneur | `Chaque conteneur doit déclarer resources.limits…` |
| `sizeLimit` sur chaque `emptyDir` | `Chaque emptyDir doit déclarer sizeLimit.` |
| `terminationGracePeriodSeconds` ≤ 30 | `terminationGracePeriodSeconds ne peut pas dépasser 30 secondes.` |
| Labels `app` et `team` sur Deployment, StatefulSet, CronJob, Job | `Le label app est obligatoire…`, `Le label team … doit valoir monequipe.` |
| Image avec digest (`nom:tag@sha256:…`, tag facultatif), jamais `:latest`, registres `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`, `rg.fr-par.scw.cloud` | `Le tag latest est interdit et un digest est obligatoire…`, `Registre non autorisé…` |
| Ingress : classe `traefik`, votre hôte et lui seul, pas d'annotation Traefik, pas de `defaultBackend` | `Hôte absent de l'annotation homelab.alson-lab.fr/allowed-hosts…`, `Annotation Traefik interdite…` |
| Service : ni `externalIPs`, ni `ExternalName`, ni NodePort, ni LoadBalancer | `spec.externalIPs est interdit.` ; quota dépassé pour les deux derniers |
| Volume : `local-path` (ou sans `storageClassName`), 1 à 10 Gi | `StorageClass non autorisée…` |
| Secret : uniquement en SealedSecret, portée strict | `Un SealedSecret d'équipe reste en portée strict…` |

Les règles exactes, telles que le cluster les applique, sont dans [`regles/admission.yaml`](../regles/admission.yaml).

**Types de ressources acceptés** : ConfigMap, PersistentVolumeClaim, Service, ServiceAccount, Deployment,
StatefulSet, HorizontalPodAutoscaler, CronJob, Job, SealedSecret, Ingress, PodDisruptionBudget. Tout le reste (Secret
en clair, Role, NetworkPolicy, Namespace…) est refusé par Argo CD : c'est l'admin qui pose ce socle.

**Quota par namespace** (à demander à l'admin s'il ne suffit pas) : 2 CPU et 2 Gi demandés, 4 CPU et 4 Gi en limite,
20 pods, 10 Services, 5 Ingress, 5 volumes pour 20 Gi, 10 SealedSecret.

**Réseau** : sortie vers Internet en TCP 80 et 443 seulement (autres ports sur demande), DNS ouvert ; aucun accès
aux réseaux privés ni aux autres namespaces ; entrée uniquement par votre nom d'hôte.

**API Kubernetes** : le ServiceAccount `default` de votre namespace ne monte pas de jeton (posé par l'admin), un pod
qui ne déclare rien n'en reçoit donc pas. Un ServiceAccount à vous, ou `automountServiceAccountToken: true`, en
monte un, mais sans aucun droit (vous ne pouvez créer ni Role ni RoleBinding). N'en demandez un que si l'app
appelle vraiment l'API ; sinon, écrivez `automountServiceAccountToken: false` dans vos pods, par clarté.

## Le dépôt de déploiement

- Argo CD lit `deploy/<app>/dev/` et `deploy/<app>/prod/` sur `main`, et rien d'autre.
- Kustomize est le format éprouvé (celui du modèle) ; un dossier de YAML bruts marche aussi. Rendu sans helm, sans
  exec ni plugins.
- Namespace : `<équipe>-<app>`, le même dans les deux clusters. Noms d'hôtes : `<app>-dev.alson-lab.fr` en dev,
  `<app>.alson-lab.fr` en prod, attribués par l'admin.

## Remis par l'admin

- Votre nom d'équipe et vos noms d'apps et d'hôtes.
- Deux **clés de déploiement** (une par cluster), à poser **en lecture seule** sur votre dépôt de déploiement
  (GitHub : Settings → Deploy keys → Add deploy key, sans cocher « Allow write access »).
- Deux certificats publics, `sealing-dev.pem` et `sealing-prod.pem`, pour chiffrer vos secrets.
- Sur demande, `homelab-dev-<équipe>.yaml` pour `kubectl` en lecture sur dev (sans secret).

## Dépannage

| Symptôme | Cause | Correction |
|---|---|---|
| Access : « That account does not have access » | Bouton « Google » au lieu d'« Authentik », compte GitHub différent de celui déclaré, ou déclaration pas encore appliquée par l'admin | Se reconnecter par « Authentik » avec le compte GitHub déclaré ; sinon, demander à l'admin |
| Authentik : « Identité … non autorisée sur ce homelab » | Compte GitHub non déclaré, ou retiré | Demander à l'admin |
| Argo CD : « Identité … non autorisée sur ce homelab » | Compte GitHub différent de celui déclaré | Se connecter à GitHub avec le compte déclaré ; sinon, demander à l'admin |
| Argo CD : aucune Application visible | Groupe d'équipe pas encore appliqué, ou première livraison pas encore faite | Attendre quelques minutes, puis demander à l'admin |
| `ComparisonError` avec une erreur d'authentification ou de dépôt introuvable | Clé de déploiement absente du dépôt, ou adresse du dépôt différente de celle déclarée | Poser les deux clés, lecture seule ; vérifier l'adresse SSH avec l'admin |
| `ComparisonError … app path does not exist` | Dossier `deploy/<app>/<env>/` absent sur `main` | Le créer et pousser |
| CI `REFUS … : <message>`, ou ressource refusée dans Argo CD | Règle du homelab | Corriger le YAML d'après la [table des règles](#les-règles), pousser |
| `is not permitted in project` | Type de ressource non accepté | Le retirer (voir la liste des types) |
| `exceeded quota` | Quota du namespace | Réduire, ou demander plus à l'admin |
| Pod en `CrashLoopBackOff` | L'app elle-même (port < 1024, écriture dans un dossier en lecture seule, root, appel système refusé par gVisor) | Image « unprivileged », port > 1024 |
| 404 sur l'hôte | Hôte de l'Ingress différent de celui attribué, ou exposition pas encore faite par l'admin | Vérifier `host:` ; demander à l'admin |
| `kubectl` : `bind: address already in use` | Port local du tunnel déjà pris | Un autre port, dans `cloudflared` et dans `server:` |
| `kubectl` : `Forbidden` | Action hors de vos droits (lecture et `exec` seulement), ou mauvaise identité | Voir l'[usage](usage.md#kubectl-sur-dev) ; `kubectl oidc-login clean` |

## Ce que le homelab ne garantit pas

À lire avant d'y mettre quoi que ce soit d'important.

- **Données** : les volumes ne sont **pas sauvegardés**. Sauvegardez vous-même ce qui compte (export vers votre
  propre stockage). Pas de base de données fournie par la plateforme.
- **Disponibilité** : un seul serveur, une seule fibre domestique, aucun engagement de service. Coupures possibles
  (maintenance, panne, mise à jour), sans préavis garanti.
- **Journaux** : seuls ceux des pods en cours d'exécution se lisent, dans Argo CD ou par `kubectl` en dev ; rien
  n'est conservé.
- **Notifications** : aucune. Une livraison refusée ou en échec se voit dans Argo CD, nulle part ailleurs.
- **Délai** : Argo CD relit votre dépôt de déploiement toutes les 3 minutes environ (pas de webhook).
- **Retour arrière** : par `git revert` sur `main`. Le retour arrière de l'interface d'Argo CD est refusé, la
  synchronisation étant automatique : `main` reste la seule vérité. Un revert remet les manifests et l'image, pas
  les données : une migration de schéma déjà jouée, un volume déjà modifié restent en l'état ; prévoyez des
  migrations compatibles avec la version précédente.
- **Votre code** : personne ne le relit avant la production. Protégez `main` (revue obligatoire, pas de
  force-push) et retirez les droits d'un membre qui part.
- **App publique** : en prod, votre hôte est ouvert à tout Internet, sauf si vous avez demandé Access. Votre app
  porte sa propre authentification.
- **gVisor** : certaines apps n'y fonctionnent pas, et les écritures disque sont plus lentes.
- **Sortie Internet** : elle part avec l'adresse IP du domicile de l'admin. Un usage abusif (scan, envoi massif,
  relais) entraîne l'arrêt immédiat de vos apps.

## Ce que vous ne pouvez pas faire

Créer un namespace, toucher aux autres équipes, ouvrir un port public autre que votre hôte HTTPS, joindre le réseau
de la maison, lancer un conteneur privilégié ou root, écrire dans le cluster autrement que par `main`. C'est voulu :
votre code arrive en production sans relecture de l'admin, ces règles sont la garantie qui le permet.
