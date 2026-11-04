# HomeOps — MPD v1.1 (PostgreSQL 17)

Dérivé du [MLD v1.1](MLD.md). Le script [`MPD.sql`](MPD.sql) **fait référence** : la configuration EF Core reprend ses
types et ses noms, et la première migration doit produire le même schéma (comparaison `pg_dump -s` en CI).
[`MPD-tests.sql`](MPD-tests.sql) vérifie chaque contrainte : 71 cas, 0 échec sur PostgreSQL 17.11 (4 novembre 2026).

## Conventions

| Sujet | Règle |
|---|---|
| Noms | snake_case, tables au singulier ; objets nommés `pk_`, `fk_`, `ak_` (clé alternative), `ix_` (index, unique ou non), `ck_` |
| Identifiants | `uuid` générés par l'application ; singletons en `smallint` fixé à 1 |
| Dates | `timestamptz`, stockage UTC |
| Mesures et montants | `numeric` ; `NaN`, infinis et négatifs refusés par `CHECK` |
| Énumérations | `text` + `CHECK`, valeurs en anglais majuscules ; exception : `docker_association.last_state` reprend les états Docker en minuscules |
| Unicité | index uniques ; contraintes `UNIQUE` réservées aux clés alternatives ciblées par une FK composite |
| Concurrence optimiste | `probe` et `docker_association` : colonne `revision` (contrat §14.1, insensible aux écritures du worker) ; autres tables : colonne système `xmin` |

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

- `admin_account` : seul le `PasswordHasher` d'ASP.NET Core Identity est utilisé (REQ-A03), sans ses tables ; verrouillage
  (`failed_login_count`, `lockout_until`, REQ-A04) et sessions (`auth_session`) sont gérés par HomeOps. Pas de `security_stamp` :
  changer le mot de passe révoque les sessions dans `auth_session` (REQ-A06).
- `instance_settings` : pas de `schema_version`, déjà tenue par l'historique des migrations EF Core ; `tls_warning_days` = seuil
  d'alerte TLS (30 j, de 1 à 90, §7.2).
- `auth_session.credential_version` : version du secret kiosque, comparée à chaque requête (§5.1).
- `intervention.idempotency_key` : clé fournie par le client, distincte de l'identifiant d'opération (REQ-D08, §10.2).
- `energy_source.credential_protected` : identifiants chiffrés par Data Protection, jamais renvoyés (§15.1).
- `probe_state.tls_episode_*` : l'épisode TLS est identifié par l'empreinte du certificat (DEC08) ; séries en `integer`.

## Notes EF Core (Npgsql)

- `UseSnakeCaseNamingConvention`, `ToTable` explicite (tables au singulier), `HasConstraintName` / `HasDatabaseName` pour les noms ci-dessus.
- Index partiels : `HasFilter` ; `CHECK` : `HasCheckConstraint` ; FK composites : `HasPrincipalKey` vers les clés `ak_` (colonnes non nulles).
- Singletons : `ValueGeneratedNever` ; énumérations : convertisseur vers les valeurs majuscules ; dates : `DateTimeOffset` en UTC.
- Jeton `xmin` : `IsRowVersion()` ; `revision` : `IsConcurrencyToken()`. Les écritures du worker passent par `ExecuteUpdate`.
- `OnDelete(Cascade)` explicite sur les deux FK de `notification_outbox`. Aucun SQL brut n'est nécessaire.
- Les clés Data Protection sont partagées entre Web et worker : le worker déchiffre les identifiants de la prise.

## Laissé à l'application
- Limites : ≤ 20 services (verrou `FOR UPDATE` sur `instance_settings`), ≤ 3 sondes non retirées par service (verrou sur `service`).
- REQ-S07 : la suppression d'un service verrouille ses liaisons (`FOR UPDATE`) avant de vérifier l'absence d'intervention
  bloquante, comme le fait la création d'intervention (§10.2).
- Cohérence d'un intervalle d'énergie : ses deux relevés appartiennent à son époque (vérifié par le worker à la création).
- Cohérence `service.mode` / maintenance active, validité IANA du fuseau, intervalle TLS par défaut (24 h, constante).
- Purges par lots de 1000 (§13.3), par sonde ou par source pour suivre les index : intervalles puis relevés à 30 j, résultats et
  contrôles immédiats à 30 j, audit à 90 j, file d'envoi terminée à 30 j, sessions expirées.
