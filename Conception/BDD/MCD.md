# HomeOps — MCD v1.3 (Merise)

Schéma unifié : [`MCD.svg`](MCD.svg) · [`MCD.png`](MCD.png).
14 entités, 12 associations, aucune association n,n. Attributs techniques (verrous, empreintes,
révisions de lignes, file d'envoi, journaux) hors MCD : ils relèvent du MLD/MPD.

Notation : premier attribut = identifiant · cardinalités `(min,max)` côté entité · `X` = exclusion.

## Entités

| Domaine | Entité | Attributs |
|---|---|---|
| Instance | PARAMETRES_INSTANCE | idInstance, fuseau, emailNotification, themeDefaut, reductionAnimations, intervalleDefaut, timeoutDefaut, seuilEchecsDefaut, seuilReussitesDefaut, initialiseLe |
| | ADMINISTRATEUR | idAdmin, login, creeLe, derniereConnexion |
| Supervision | SERVICE | idService, nom, adresse, description, notesDepannage, modeSurveillance |
| | SONDE | idSonde, nom, type, cible, port, sni, intervalle, timeout, statutAttendu, seuilEchecs, seuilReussites, revision, retireeLe |
| | RESULTAT | idResultat, observeLe, dureeMs, issue, codeErreur, statutHttp, tlsExpireLe, revisionSonde* |
| Incidents | INCIDENT | idIncident, etat, premierEchecLe, ouvertLe, acquitteLe, resoluLe, closLe, motifCloture, cibleOrigine*, typeOrigine*, revisionSonde* |
| | NOTE | idNote, texte, creeeLe |
| | NOTIFICATION | idNotification, type, destinataire*, creeeLe, etatEnvoi |
| Exploitation | MAINTENANCE | idMaintenance, debutLe, finPrevue, finEffective, motif |
| | LIAISON_DOCKER | idLiaison, refConnecteur, refConteneur, debutValidite, finValidite, dernierEtat |
| | INTERVENTION | idIntervention, action, etat, demandeeLe, lanceeLe, termineeLe, codeResultat, verrouLeveLe, motifLevee |
| Énergie | SOURCE_ENERGIE | idSource, identitePrise, mode, active, adresse, tarif, puissanceMax |
| | EPOQUE_COMPTEUR | idEpoque, debutLe, finLe, motifOuverture |
| | RELEVE_ENERGIE | idReleve, observeLe, puissanceW, compteurWh, qualite |

\* Instantané historisé : valeur figée à la création (la sonde ou l'adresse peut changer ensuite), pas une dépendance transitive.
`etat` (INCIDENT, INTERVENTION) est l'état de la machine métier (§8.1, §10.2), non déductible des seules dates (ex. UNKNOWN, CLOSED).
`refConnecteur` / `refConteneur` : identifiants externes côté Docker, pas des clés.
`retireeLe` : une sonde retirée n'est plus exécutée mais garde son historique (incidents, notes) tant que le service existe (§13.3).
`verrouLeveLe` / `motifLevee` : levée locale du blocage d'une intervention UNKNOWN, qui reste UNKNOWN (REQ-D10, §10.5).

## Associations

| Association | Entité A (card.) | Entité B (card.) |
|---|---|---|
| equiper | SERVICE (0,3) | SONDE (1,1) |
| produire | SONDE (0,n) | RESULTAT (1,1) |
| detecter | SONDE (0,n) | INCIDENT (1,1) |
| documenter | INCIDENT (0,n) | NOTE (1,1) |
| signaler | INCIDENT (0,n) | NOTIFICATION (0,1) |
| concerner | SONDE (0,n) | NOTIFICATION (0,1) |
| planifier | SERVICE (0,n) | MAINTENANCE (1,1) |
| rattacher | SERVICE (0,n) | LIAISON_DOCKER (1,1) |
| cibler | LIAISON_DOCKER (0,n) | INTERVENTION (1,1) |
| ouvrir | SOURCE_ENERGIE (0,n) | EPOQUE_COMPTEUR (1,1) |
| mesurer | SOURCE_ENERGIE (0,n) | RELEVE_ENERGIE (1,1) |
| regrouper | EPOQUE_COMPTEUR (0,n) | RELEVE_ENERGIE (0,1) |

## Contraintes hors cardinalités

| ID | Règle |
|---|---|
| CIF-1 | Au plus 1 INCIDENT actif (OPEN, ACKNOWLEDGED) par SONDE |
| CIF-2 | Au plus 1 MAINTENANCE active par SERVICE |
| CIF-3 | Au plus 1 LIAISON_DOCKER active par SERVICE ; un couple connecteur/conteneur actif sur au plus 1 SERVICE |
| CIF-4 | Au plus 1 INTERVENTION bloquante (non terminée, ou UNKNOWN non levée) par couple connecteur/conteneur, liaisons historiques comprises |
| CIF-5 | Un RELEVE_ENERGIE valide appartient à une époque de sa propre SOURCE_ENERGIE ; un relevé en erreur sans référence peut n'en avoir aucune |
| CIF-6 | Au plus 1 EPOQUE_COMPTEUR courante par SOURCE_ENERGIE ; au plus 1 SOURCE_ENERGIE active |
| NOTIF (X) | `signaler` et `concerner` exclusives : TEST → aucune ; TLS → `concerner` ; OUVERTURE / RETABLISSEMENT → `signaler` |
| SINGL | PARAMETRES_INSTANCE : 1 occurrence ; ADMINISTRATEUR : 0 avant initialisation, 1 après |
| LIMITES | Au plus 3 SONDE non retirées par SERVICE (borne 0,3 de `equiper`) ; au plus 20 SERVICE |
| UNIQ | SERVICE.nom unique (insensible à la casse) ; RELEVE_ENERGIE unique par (source, observeLe) |

## Changements v1.3 (revue du MLD)
- SONDE.`retireeLe` : retrait logique, pour ne pas effacer l'historique d'incidents (§13.3).
- INTERVENTION.`verrouLeveLe` / `motifLevee` : levée du blocage UNKNOWN (REQ-D10).

## Changements depuis v1.1
- Liens vers ADMINISTRATEUR supprimés (`demander`, `rediger`, `declencher`, `acquitter`) : compte unique (RM22),
  ils ne portent aucune information. `dateAcquittement` devient `INCIDENT.acquitteLe`.
- `justifie` supprimée : l'origine est portée par INCIDENT (`premierEchecLe`, `cibleOrigine`, `typeOrigine`), résultat purgé à 30 jours.
- `concerner` (SERVICE–NOTIFICATION) supprimée : le service se déduit de la sonde ; notification d'incident → `signaler` seul.
- Renommages : `porter_sur` → `concerner`, `viser` → `cibler`, `identifiant` → `login`, `idConnecteur/idConteneur` → `ref…`.
- 1FN : `seuils` et `defautsSondes` éclatés.
- Attributs techniques retirés (empreintes, verrous, snapshot, credential, file d'envoi, `versionSchema`, `revisionMode`).
- PARAMETRES_INSTANCE et ADMINISTRATEUR restent sans association : singletons, volontaire.

Traduction relationnelle : voir [MLD.md](MLD.md).
