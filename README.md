# HomeOps

Application web **auto-hébergée** de supervision de homelab : inventaire des services,
surveillance de disponibilité (HTTP/HTTPS, TCP, expiration TLS), diagnostic d'incidents,
pilotage Docker limité (démarrer / arrêter / redémarrer des conteneurs autorisés) et
suivi de consommation électrique via une prise compatible. Une instance par détenteur,
un seul compte administrateur.

Ce dépôt contient la **conception** du projet (périmètre, spécification, schémas,
maquettes), pas encore le code applicatif.

## Structure

```
Docs/
  HomeOps-PERIMETRE.docx              Fiche de périmètre MVP (règles métier RM01–RM26)
  HomeOps-SPECIFICATION.docx          Spécification fonctionnelle et technique — v1.3,
                                      111 exigences, 36 recettes, 15 schémas, 17 décisions, MCD
  HomeOps-DOSSIER-CERTIFICATION.docx  Dossier de certification
Conception/
  BDD/                                Modèles Merise : MCD v1.2 (MCD.md, .svg, .png) ; MLD, MPD à venir
  Cas-utilisation/                    7 vues cas d'usage UML (accès, services, consultation,
                                      incidents, pilotage, réglages/alertes, énergie)
  Maquettes/                          7 captures d'écran de référence (thème clair)
homeops-sync.ps1                      Script de synchronisation git multi-postes
.gitignore                            Fichiers temporaires Office/Windows
```

> Les figures (cas d'usage, MCD, architecture…) sont intégrées dans la spécification ;
> les PNG de `Cas-utilisation/` en sont un export découpé, à garder alignés sur le document.

## Statut

Spécification **v1.3 figée** (3 novembre 2026) : fonctionnalités, règles métier, contrats,
critères de recette et MCD (schéma unique FIG04).
**MLD / MPD à produire** lors de la conception détaillée.
Le gel ne vaut ni implémentation ni test réalisé.

## Travailler depuis plusieurs postes

Le dépôt est synchronisé via Git pour alterner entre le PC portable et le PC fixe.
Les `.docx` / `.png` sont binaires et ne fusionnent pas : **synchroniser au début et à la
fin de chaque session** pour éviter les conflits.

### Avec le script (recommandé)

```powershell
cd C:\Users\...\HomeOps
.\homeops-sync.ps1                       # pull --rebase + commit + push, en une commande
.\homeops-sync.ps1 -Message "Ajout MLD"  # message de commit personnalisé
.\homeops-sync.ps1 -Force                # passer outre l'alerte « fichier Office ouvert »
```

Le script refuse de committer si un document Office est encore ouvert (verrou `~$...`) ;
ferme-le puis relance, ou utilise `-Force`.

### À la main

```bash
git clone https://github.com/Kapetaine-dev/HomeOps.git   # nouveau poste
git pull            # avant de commencer
git add . && git commit -m "…" && git push               # pour partager
```
