# HomeOps — MLD v1.1 (Merise)

Dérivé du [MCD v1.4](MCD.md) · schéma : [`MLD.svg`](MLD.svg) · [`MLD.png`](MLD.png) · traduction physique : [MPD](MPD.md).
14 relations, 12 clés étrangères, aucune table de jonction.

**Notation** : premier attribut = clé primaire · `#` = clé étrangère · `?` = nullable · `U` = unique.
**Règles** : patte (1,1) → FK obligatoire ; patte (0,1) → FK nullable. Noms conceptuels conservés ;
les noms physiques (`Service`, `Probe`…) et les tables techniques (sessions, audit, file d'envoi…) relèvent du MPD (spec §13.1).

## Relations

| Domaine | Relation |
|---|---|
| Instance | **PARAMETRES_INSTANCE** (idInstance, fuseau, emailNotification?, themeDefaut, reductionAnimations, intervalleDefaut, timeoutDefaut, seuilEchecsDefaut, seuilReussitesDefaut, seuilAlerteTls, initialiseLe?) |
| | **ADMINISTRATEUR** (idAdmin, login U, creeLe, derniereConnexion?) |
| Supervision | **SERVICE** (idService, nom, nomNormalise U, adresse, description?, notesDepannage?, modeSurveillance) |
| | **SONDE** (idSonde, nom, type, cible, port?, sni?, intervalle, timeout, statutAttendu?, seuilEchecs, seuilReussites, revision, retireeLe?, #idService) |
| | **RESULTAT** (idResultat, observeLe, dureeMs, issue, codeErreur?, statutHttp?, tlsExpireLe?, revisionSonde, #idSonde) |
| Incidents | **INCIDENT** (idIncident, etat, premierEchecLe, ouvertLe, acquitteLe?, resoluLe?, closLe?, motifCloture?, cibleOrigine, typeOrigine, revisionSonde, #idSonde) |
| | **NOTE** (idNote, texte, creeeLe, #idIncident) |
| | **NOTIFICATION** (idNotification, type, destinataire, creeeLe, etatEnvoi, #idIncident?, #idSonde?) |
| Exploitation | **MAINTENANCE** (idMaintenance, debutLe, finPrevue, finEffective?, motif?, #idService) |
| | **LIAISON_DOCKER** (idLiaison, refConnecteur, refConteneur, debutValidite, finValidite?, dernierEtat?, #idService) |
| | **INTERVENTION** (idIntervention, action, etat, demandeeLe, lanceeLe?, termineeLe?, codeResultat?, verrouLeveLe?, motifLevee?, #idLiaison, #refConnecteur, #refConteneur) |
| Énergie | **SOURCE_ENERGIE** (idSource, identitePrise, mode, active, adresse?, tarif?, puissanceMax?) |
| | **EPOQUE_COMPTEUR** (idEpoque, debutLe, finLe?, motifOuverture, #idSource) |
| | **RELEVE_ENERGIE** (idReleve, observeLe, puissanceW?, compteurWh?, qualite, #idSource, #idEpoque?) |

## Clés étrangères

| FK | Référence | Suppression |
|---|---|---|
| SONDE.idService | SERVICE | CASCADE |
| MAINTENANCE.idService | SERVICE | CASCADE |
| LIAISON_DOCKER.idService | SERVICE | CASCADE |
| RESULTAT.idSonde | SONDE | CASCADE |
| INCIDENT.idSonde | SONDE | CASCADE |
| NOTIFICATION.idSonde | SONDE | CASCADE |
| NOTE.idIncident | INCIDENT | CASCADE |
| NOTIFICATION.idIncident | INCIDENT | CASCADE |
| INTERVENTION.(idLiaison, refConnecteur, refConteneur) | LIAISON_DOCKER, clé candidate U(idLiaison, refConnecteur, refConteneur) | CASCADE |
| EPOQUE_COMPTEUR.idSource | SOURCE_ENERGIE | RESTRICT |
| RELEVE_ENERGIE.idSource | SOURCE_ENERGIE | RESTRICT |
| RELEVE_ENERGIE.(idEpoque, idSource) | EPOQUE_COMPTEUR, clé candidate U(idEpoque, idSource) | RESTRICT, MATCH SIMPLE |

- **Cascade** : seule la suppression d'un SERVICE efface son historique (REQ-S06), notifications en attente comprises (§13.3).
  Une sonde n'est jamais supprimée physiquement : son retrait renseigne `retireeLe`, ses incidents et notes restent.
- **RESTRICT énergie** : une source ou une époque reste tant qu'un relevé la référence ; la purge supprime d'abord les relevés.
- **MATCH SIMPLE** : un relevé sans époque (`idEpoque` nul) n'est pas contrôlé par la FK composite ; `idSource` reste obligatoire.

## Contraintes

| ID | Mise en œuvre |
|---|---|
| CIF-1 | U partiel `INCIDENT(idSonde) WHERE etat IN (OPEN, ACKNOWLEDGED)` |
| CIF-2 | U partiel `MAINTENANCE(idService) WHERE finEffective IS NULL` (le worker renseigne `finEffective` à l'échéance) |
| CIF-3 | U partiels `LIAISON_DOCKER(idService)` et `LIAISON_DOCKER(refConnecteur, refConteneur)` `WHERE finValidite IS NULL` |
| CIF-4 | U partiel `INTERVENTION(refConnecteur, refConteneur) WHERE etat IN (QUEUED, RUNNING, UNKNOWN) AND verrouLeveLe IS NULL` |
| CIF-5 | FK composite `RELEVE(idEpoque, idSource)` + `CHECK (qualite <> 'VALIDE' OR idEpoque IS NOT NULL)` |
| CIF-6 | U partiels `EPOQUE_COMPTEUR(idSource) WHERE finLe IS NULL` et `SOURCE_ENERGIE(active) WHERE active` |
| NOTIF | `CHECK` : TEST → les deux FK nulles ; TLS → `idSonde` seule ; OUVERTURE / RETABLISSEMENT → `idIncident` seule |
| INCIDENT | `CHECK` : OPEN/ACKNOWLEDGED ⇒ `resoluLe`, `closLe` nuls ; RESOLVED ⇒ `resoluLe` ; CLOSED ⇒ `closLe`, `motifCloture = CONFIGURATION_REPLACED`, `resoluLe` nul ; dates ordonnées (`premierEchecLe ≤ ouvertLe ≤ acquitteLe, resoluLe, closLe`) |
| VALEURS | `CHECK` : `finPrevue > debutLe` ; NOTE.texte de 1 à 4000 caractères ; relevé VALIDE ⇒ `compteurWh` non nul et non `NaN` |
| SINGL | `CHECK` sur un identifiant fixe pour PARAMETRES_INSTANCE et ADMINISTRATEUR ; la ligne de paramètres est créée à l'installation |
| UNIQ | U `SERVICE(nomNormalise)` (minuscules, espaces réduits) ; U `RELEVE_ENERGIE(idSource, observeLe)` |
| LIMITES | ≤ 3 sondes non retirées par service, ≤ 20 services : contrôle transactionnel applicatif (non déclaratif) |

## Choix de dérivation
- **Dénormalisation contrôlée** : `refConnecteur` / `refConteneur` sont recopiés dans INTERVENTION (dépendance transitive via
  `idLiaison`, donc hors 3FN). C'est la solution déclarative la plus simple pour CIF-4 entre liaisons historiques ;
  la FK composite vers la clé candidate de LIAISON_DOCKER garantit que la copie reste identique.
- CIF-5 est garantie par la structure (FK composite) plutôt que par du code.
- ADMINISTRATEUR et PARAMETRES_INSTANCE sans FK : singletons ; l'acteur d'une action est tracé par l'audit (MPD).

## Traité dans le MPD
- Unicités techniques : `eventKey` + destinataire de la file d'envoi (REQ-N01), `executionId` des résultats (REQ-P10).
- Tables techniques de §13.1 (sessions, CheckRequest, ProbeState, AuditEvent, EnergyInterval, WorkerHeartbeat), types, index de lecture.
