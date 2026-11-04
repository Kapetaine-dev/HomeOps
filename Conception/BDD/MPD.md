# HomeOps — MPD v1 (PostgreSQL 17)

Dérivé du [MLD v1.1](MLD.md). Le script [`MPD.sql`](MPD.sql) **fait référence** : la configuration EF Core s'y conforme
et la première migration doit produire le même schéma. [`MPD-tests.sql`](MPD-tests.sql) vérifie chaque contrainte
(65 cas, 0 échec sur PostgreSQL 17.11, 4 novembre 2026).

## Conventions

| Sujet | Règle |
|---|---|
| Noms | snake_case, tables au singulier (EF Core : `UseSnakeCaseNamingConvention`) |
| Identifiants | `uuid` générés par l'application ; singletons en `smallint` fixé à 1 |
| Dates | `timestamptz`, stockage UTC |
| Mesures et montants | `numeric` ; `NaN`, infinis et négatifs refusés par `CHECK` |
| Énumérations | `text` + `CHECK (… IN (…))`, valeurs en anglais majuscules |
| Concurrence optimiste | colonne système `xmin` (jeton EF Core) : pas de colonne `row_version` |
| EF Core | index partiels via `HasFilter`, `CHECK` via `HasCheckConstraint`, FK composites via `HasPrincipalKey` : aucun SQL brut nécessaire |

## Correspondance MLD → tables

| MLD | Table | MLD | Table |
|---|---|---|---|
| PARAMETRES_INSTANCE | `instance_settings` | MAINTENANCE | `maintenance` |
| ADMINISTRATEUR | `admin_account` | LIAISON_DOCKER | `docker_association` |
| SERVICE | `service` | INTERVENTION | `intervention` |
| SONDE | `probe` | SOURCE_ENERGIE | `energy_source` |
| RESULTAT | `probe_result` | EPOQUE_COMPTEUR | `energy_epoch` |
| INCIDENT | `incident` | RELEVE_ENERGIE | `energy_reading` |
| NOTE | `incident_note` | NOTIFICATION | `notification_outbox` |

Tables techniques (spec §13.1) : `auth_session`, `check_request`, `probe_state`, `energy_interval`, `audit_event`,
`worker_heartbeat`. Le journal du connecteur reste en SQLite local au connecteur, hors de ce schéma.

Valeurs renommées : OUVERTURE → `INCIDENT_OPENED`, RETABLISSEMENT → `INCIDENT_RESOLVED`, TLS → `TLS_WARNING`,
VALIDE → `VALID`, EXPLOITANT → `OPERATOR`. Attributs : noms anglais du §13.1 en snake_case.

## Précisions par rapport au §13.1

- `admin_account` : seul le `PasswordHasher` d'ASP.NET Core Identity est utilisé (REQ-A03), sans les tables Identity ;
  verrouillage (`failed_login_count`, `lockout_until`, REQ-A04) et sessions (`auth_session`) sont gérés par HomeOps.
- `auth_session.credential_version` : version du secret kiosque, comparée à chaque requête (§5.1).
- `intervention.idempotency_key` : clé fournie par le client, distincte de l'identifiant d'opération (REQ-D08).
- `energy_source.credential_protected` : identifiants chiffrés par Data Protection, jamais renvoyés (§15.1).
- `instance_settings.tls_warning_days` : seuil d'alerte TLS (30 j, de 1 à 90, §7.2), réglage global.
- `probe_state.tls_episode_*` : l'épisode TLS est identifié par l'empreinte du certificat (DEC08).
- `energy_interval` : FK composites (relevé, époque) : les deux relevés d'un intervalle sont de la même époque.

## Laissé à l'application
- Limites : ≤ 3 sondes non retirées par service, ≤ 20 services (contrôle en transaction).
- Cohérence `service.mode` / maintenance active, validité IANA du fuseau, intervalle TLS par défaut (24 h, constante).
- Purges par lots (§13.3) : résultats et relevés à 30 j, audit à 90 j, file d'envoi terminée à 30 j.
