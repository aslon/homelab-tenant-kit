"""Contrôle statique de ce qu'un dry-run ne voit pas (ADR-051) : LimitRange par pod et quota du namespace.

Lit sur l'entrée standard le rendu d'une app (un objet JSON par ligne), et dans l'environnement le quota (QUOTAS) et
le maximum par pod (MAXPOD) du socle, en JSON. Imprime un message par dépassement, rien sinon. Le total est une
estimation : réplicas déclarés, hors HPA, un pod par CronJob.
"""

import json
import os
import sys

UNITES = {"Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "m": 1e-3, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12}


def qty(v):
    v = str(v)
    for u in sorted(UNITES, key=len, reverse=True):
        if v.endswith(u):
            return float(v[: -len(u)]) * UNITES[u]
    return float(v)


def somme(conteneurs, cle, res):
    return sum(qty(((c.get("resources") or {}).get(cle) or {}).get(res, 0)) for c in conteneurs or [])


def par_pod(pod, cle, res):
    # Un pod réserve le maximum entre la somme de ses conteneurs et chacun de ses initContainers.
    init = [somme([c], cle, res) for c in pod.get("initContainers") or []]
    return max([somme(pod.get("containers"), cle, res)] + init)


def main():
    quotas = json.loads(os.environ["QUOTAS"])
    maxpod = json.loads(os.environ["MAXPOD"])
    total = dict.fromkeys(
        ["limits.cpu", "limits.memory", "requests.cpu", "requests.memory", "pods", "requests.storage", "persistentvolumeclaims"], 0.0
    )
    for ligne in sys.stdin:
        if not ligne.strip():
            continue
        o = json.loads(ligne)
        if not isinstance(o, dict):
            continue
        kind, spec = o.get("kind"), o.get("spec") or {}
        nom = "%s %s" % (kind, (o.get("metadata") or {}).get("name", "?"))
        if kind == "PersistentVolumeClaim":
            total["persistentvolumeclaims"] += 1
            total["requests.storage"] += qty(((spec.get("resources") or {}).get("requests") or {}).get("storage", 0))
            continue
        if kind in ("Deployment", "StatefulSet"):
            pod, n = (spec.get("template") or {}).get("spec") or {}, spec.get("replicas", 1)
        elif kind == "Job":
            pod, n = (spec.get("template") or {}).get("spec") or {}, spec.get("parallelism", 1)
        elif kind == "CronJob":
            pod, n = (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}, 1
        else:
            continue
        for res in ("cpu", "memory"):
            lim = par_pod(pod, "limits", res)
            if res in maxpod and lim > qty(maxpod[res]):
                print("%s : limits.%s par pod au-dessus du maximum %s (LimitRange)" % (nom, res, maxpod[res]))
            total["limits." + res] += n * lim
            total["requests." + res] += n * par_pod(pod, "requests", res)
        total["pods"] += n
    for cle, v in total.items():
        if cle in quotas and v > qty(quotas[cle]):
            print("somme %s des ressources (%g) au-dessus du quota %s (estimation : réplicas déclarés, hors HPA)" % (cle, v, quotas[cle]))


if __name__ == "__main__":
    main()
