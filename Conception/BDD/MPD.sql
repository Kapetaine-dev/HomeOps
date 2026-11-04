-- HomeOps — MPD v1 — PostgreSQL 17
-- Dérivé du MLD v1.1 (MLD.md). Référence du schéma : la configuration EF Core doit s'y conformer.
-- Conventions : snake_case, uuid applicatifs, timestamptz (UTC), numeric pour les mesures, énumérations en text + CHECK.
-- Concurrence optimiste : colonne système xmin (EF Core), aucune colonne row_version.

BEGIN;

-- ============================================================ Instance et accès

CREATE TABLE instance_settings (
    id                        smallint     PRIMARY KEY CHECK (id = 1),
    initialized_at            timestamptz,
    timezone                  varchar(64)  NOT NULL DEFAULT 'Europe/Paris',
    schema_version            varchar(32)  NOT NULL,
    notification_email        varchar(254) CHECK (notification_email !~ '[\r\n]'),
    theme_default             text         NOT NULL DEFAULT 'LIGHT' CHECK (theme_default IN ('LIGHT', 'DARK', 'RED')),
    reduce_motion             boolean      NOT NULL DEFAULT false,
    default_interval_seconds  integer      NOT NULL DEFAULT 60 CHECK (default_interval_seconds BETWEEN 30 AND 3600),
    default_timeout_seconds   integer      NOT NULL DEFAULT 5  CHECK (default_timeout_seconds BETWEEN 1 AND 15),
    default_fail_threshold    smallint     NOT NULL DEFAULT 3  CHECK (default_fail_threshold BETWEEN 1 AND 10),
    default_success_threshold smallint     NOT NULL DEFAULT 2  CHECK (default_success_threshold BETWEEN 1 AND 10),
    tls_warning_days          smallint     NOT NULL DEFAULT 30 CHECK (tls_warning_days BETWEEN 1 AND 90)
);

CREATE TABLE admin_account (
    id                        smallint     PRIMARY KEY CHECK (id = 1),
    login                     varchar(80)  NOT NULL,
    normalized_login          varchar(80)  NOT NULL UNIQUE,
    password_hash             text         NOT NULL,
    security_stamp            uuid         NOT NULL,
    failed_login_count        smallint     NOT NULL DEFAULT 0 CHECK (failed_login_count >= 0),
    lockout_until             timestamptz,
    created_at                timestamptz  NOT NULL,
    last_successful_login_at  timestamptz
);

CREATE TABLE auth_session (
    id_hash                   bytea        PRIMARY KEY,
    principal_type            text         NOT NULL CHECK (principal_type IN ('ADMIN', 'KIOSK')),
    admin_account_id          smallint     REFERENCES admin_account (id) ON DELETE CASCADE,
    credential_version        varchar(64),
    created_at                timestamptz  NOT NULL,
    last_seen_at              timestamptz  NOT NULL,
    expires_at                timestamptz  NOT NULL,
    absolute_expires_at       timestamptz  NOT NULL,
    revoked_at                timestamptz,
    CHECK ((principal_type = 'ADMIN') = (admin_account_id IS NOT NULL)),
    CHECK (principal_type = 'ADMIN' OR credential_version IS NOT NULL),
    CHECK (expires_at <= absolute_expires_at)
);
CREATE INDEX auth_session_expiry_idx ON auth_session (absolute_expires_at);

-- ============================================================ Supervision

CREATE TABLE service (
    id                        uuid         PRIMARY KEY,
    name                      varchar(80)  NOT NULL CHECK (name <> ''),
    normalized_name           varchar(80)  NOT NULL UNIQUE,
    address                   varchar(2048) NOT NULL CHECK (address <> ''),
    description               varchar(500),
    troubleshooting_notes     varchar(10000),
    mode                      text         NOT NULL DEFAULT 'NORMAL' CHECK (mode IN ('NORMAL', 'MAINTENANCE', 'SUSPENDED')),
    mode_revision             integer      NOT NULL DEFAULT 0
);

CREATE TABLE probe (
    id                        uuid         PRIMARY KEY,
    service_id                uuid         NOT NULL REFERENCES service (id) ON DELETE CASCADE,
    name                      varchar(80)  NOT NULL CHECK (name <> ''),
    type                      text         NOT NULL CHECK (type IN ('HTTP', 'TCP', 'TLS')),
    target                    varchar(2048) NOT NULL CHECK (target <> ''),
    port                      integer      CHECK (port BETWEEN 1 AND 65535),
    sni                       varchar(253),
    interval_seconds          integer      NOT NULL,
    timeout_seconds           integer      NOT NULL CHECK (timeout_seconds BETWEEN 1 AND 15),
    expected_status           smallint     CHECK (expected_status BETWEEN 100 AND 599),
    fail_threshold            smallint     NOT NULL CHECK (fail_threshold BETWEEN 1 AND 10),
    success_threshold         smallint     NOT NULL CHECK (success_threshold BETWEEN 1 AND 10),
    revision                  integer      NOT NULL DEFAULT 1,
    retired_at                timestamptz,
    next_due_at               timestamptz,
    CHECK ((type = 'HTTP') = (port IS NULL)),
    CHECK ((type = 'HTTP') = (expected_status IS NOT NULL)),
    CHECK (sni IS NULL OR type = 'TLS'),
    CHECK (CASE type WHEN 'TLS' THEN interval_seconds BETWEEN 3600 AND 86400
                     ELSE interval_seconds BETWEEN 30 AND 3600 END),
    CHECK (interval_seconds > timeout_seconds)
);
CREATE INDEX probe_service_idx ON probe (service_id);
CREATE INDEX probe_due_idx ON probe (next_due_at) WHERE retired_at IS NULL;

CREATE TABLE probe_result (
    id                        uuid         PRIMARY KEY,
    execution_id              uuid         NOT NULL UNIQUE,
    probe_id                  uuid         NOT NULL REFERENCES probe (id) ON DELETE CASCADE,
    probe_revision            integer      NOT NULL,
    mode_revision             integer      NOT NULL,
    started_at                timestamptz  NOT NULL,
    observed_at               timestamptz  NOT NULL,
    duration_ms               integer      NOT NULL CHECK (duration_ms >= 0),
    outcome                   text         NOT NULL CHECK (outcome IN ('PASS', 'FAIL', 'ERROR_INTERNAL')),
    error_code                varchar(64),
    http_status               smallint     CHECK (http_status BETWEEN 100 AND 599),
    tls_not_after             timestamptz,
    fingerprint               varchar(128),
    CHECK (observed_at >= started_at)
);
CREATE INDEX probe_result_probe_idx ON probe_result (probe_id, observed_at DESC);
CREATE INDEX probe_result_purge_idx ON probe_result (observed_at);

CREATE TABLE probe_state (
    probe_id                  uuid         PRIMARY KEY REFERENCES probe (id) ON DELETE CASCADE,
    fail_streak               smallint     NOT NULL DEFAULT 0 CHECK (fail_streak >= 0),
    success_streak            smallint     NOT NULL DEFAULT 0 CHECK (success_streak >= 0),
    first_failure_at          timestamptz,
    last_applied_result_id    uuid         REFERENCES probe_result (id) ON DELETE SET NULL,
    health_state              text         NOT NULL DEFAULT 'UNKNOWN' CHECK (health_state IN ('UNKNOWN', 'UP', 'DOWN')),
    tls_episode_fingerprint   varchar(128),
    tls_episode_started_at    timestamptz,
    tls_notified_at           timestamptz,
    CHECK ((tls_episode_fingerprint IS NULL) = (tls_episode_started_at IS NULL))
);

CREATE TABLE check_request (
    id                        uuid         PRIMARY KEY,
    probe_id                  uuid         NOT NULL REFERENCES probe (id) ON DELETE CASCADE,
    idempotency_key           uuid         NOT NULL UNIQUE,
    requested_at              timestamptz  NOT NULL,
    state                     text         NOT NULL DEFAULT 'PENDING' CHECK (state IN ('PENDING', 'RUNNING', 'DONE', 'FAILED')),
    result_id                 uuid         REFERENCES probe_result (id) ON DELETE SET NULL
);
CREATE UNIQUE INDEX check_request_active_uq ON check_request (probe_id) WHERE state IN ('PENDING', 'RUNNING');

-- ============================================================ Incidents et notifications

CREATE TABLE incident (
    id                        uuid         PRIMARY KEY,
    probe_id                  uuid         NOT NULL REFERENCES probe (id) ON DELETE CASCADE,
    probe_revision            integer      NOT NULL,
    target_snapshot           varchar(2048) NOT NULL,
    type_snapshot             text         NOT NULL CHECK (type_snapshot IN ('HTTP', 'TCP', 'TLS')),
    status                    text         NOT NULL CHECK (status IN ('OPEN', 'ACKNOWLEDGED', 'RESOLVED', 'CLOSED')),
    first_failure_at          timestamptz  NOT NULL,
    opened_at                 timestamptz  NOT NULL,
    acknowledged_at           timestamptz,
    resolved_at               timestamptz,
    closed_at                 timestamptz,
    closure_reason            text         CHECK (closure_reason IN ('CONFIGURATION_REPLACED')),
    CHECK (status NOT IN ('OPEN', 'ACKNOWLEDGED') OR (resolved_at IS NULL AND closed_at IS NULL)),
    CHECK (status <> 'ACKNOWLEDGED' OR acknowledged_at IS NOT NULL),
    CHECK ((status = 'RESOLVED') = (resolved_at IS NOT NULL)),
    CHECK ((status = 'CLOSED') = (closed_at IS NOT NULL)),
    CHECK ((status = 'CLOSED') = (closure_reason IS NOT NULL)),
    CHECK (first_failure_at <= opened_at),
    CHECK (acknowledged_at IS NULL OR acknowledged_at >= opened_at),
    CHECK (resolved_at IS NULL OR resolved_at >= opened_at),
    CHECK (closed_at IS NULL OR closed_at >= opened_at)
);
CREATE UNIQUE INDEX incident_active_uq ON incident (probe_id) WHERE status IN ('OPEN', 'ACKNOWLEDGED');

CREATE TABLE incident_note (
    id                        uuid         PRIMARY KEY,
    incident_id               uuid         NOT NULL REFERENCES incident (id) ON DELETE CASCADE,
    created_at                timestamptz  NOT NULL,
    text                      varchar(4000) NOT NULL CHECK (text <> '')
);
CREATE INDEX incident_note_incident_idx ON incident_note (incident_id, created_at);

CREATE TABLE notification_outbox (
    id                        uuid         PRIMARY KEY,
    event_key                 varchar(200) NOT NULL,
    recipient                 varchar(254) NOT NULL CHECK (recipient !~ '[\r\n]'),
    type                      text         NOT NULL CHECK (type IN ('INCIDENT_OPENED', 'INCIDENT_RESOLVED', 'TLS_WARNING', 'TEST')),
    probe_id                  uuid         REFERENCES probe (id) ON DELETE CASCADE,
    incident_id               uuid         REFERENCES incident (id) ON DELETE CASCADE,
    state                     text         NOT NULL DEFAULT 'PENDING' CHECK (state IN ('PENDING', 'SENT', 'FAILED', 'UNKNOWN', 'CANCELED')),
    attempts                  smallint     NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 3),
    next_attempt_at           timestamptz,
    message_id                varchar(255),
    last_error                varchar(500),
    created_at                timestamptz  NOT NULL,
    UNIQUE (event_key, recipient),
    CHECK (CASE type
             WHEN 'TEST'        THEN probe_id IS NULL     AND incident_id IS NULL
             WHEN 'TLS_WARNING' THEN probe_id IS NOT NULL AND incident_id IS NULL
             ELSE                    probe_id IS NULL     AND incident_id IS NOT NULL
           END)
);
CREATE INDEX notification_outbox_dispatch_idx ON notification_outbox (state, next_attempt_at);
CREATE INDEX notification_outbox_probe_idx ON notification_outbox (probe_id) WHERE probe_id IS NOT NULL;
CREATE INDEX notification_outbox_incident_idx ON notification_outbox (incident_id) WHERE incident_id IS NOT NULL;

-- ============================================================ Exploitation

CREATE TABLE maintenance (
    id                        uuid         PRIMARY KEY,
    service_id                uuid         NOT NULL REFERENCES service (id) ON DELETE CASCADE,
    started_at                timestamptz  NOT NULL,
    ends_at                   timestamptz  NOT NULL,
    ended_at                  timestamptz,
    reason                    varchar(500),
    CHECK (ends_at - started_at BETWEEN interval '5 minutes' AND interval '7 days'),
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE UNIQUE INDEX maintenance_active_uq ON maintenance (service_id) WHERE ended_at IS NULL;
CREATE INDEX maintenance_service_idx ON maintenance (service_id, started_at DESC);

CREATE TABLE docker_association (
    id                        uuid         PRIMARY KEY,
    service_id                uuid         NOT NULL REFERENCES service (id) ON DELETE CASCADE,
    connector_id              varchar(100) NOT NULL,
    container_id              varchar(64)  NOT NULL CHECK (container_id ~ '^[0-9a-f]{64}$'),
    revision                  integer      NOT NULL DEFAULT 1,
    active_from               timestamptz  NOT NULL,
    inactive_at               timestamptz,
    last_state                text         CHECK (last_state IN ('created', 'running', 'paused', 'restarting',
                                                                 'removing', 'exited', 'dead', 'unknown')),
    last_observed_at          timestamptz,
    UNIQUE (id, connector_id, container_id),
    CHECK (inactive_at IS NULL OR inactive_at >= active_from)
);
CREATE UNIQUE INDEX docker_association_service_active_uq ON docker_association (service_id) WHERE inactive_at IS NULL;
CREATE UNIQUE INDEX docker_association_container_active_uq ON docker_association (connector_id, container_id) WHERE inactive_at IS NULL;

CREATE TABLE intervention (
    id                        uuid         PRIMARY KEY,
    association_id            uuid         NOT NULL,
    connector_id              varchar(100) NOT NULL,
    container_id              varchar(64)  NOT NULL,
    idempotency_key           uuid         NOT NULL UNIQUE,
    request_hash              bytea        NOT NULL,
    action                    text         NOT NULL CHECK (action IN ('START', 'STOP', 'RESTART')),
    protection_snapshot       text         CHECK (protection_snapshot IN ('MAINTENANCE', 'SUSPENDED')),
    state                     text         NOT NULL DEFAULT 'QUEUED' CHECK (state IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'UNKNOWN')),
    requested_at              timestamptz  NOT NULL,
    dispatched_at             timestamptz,
    completed_at              timestamptz,
    result_code               varchar(64),
    lock_released_at          timestamptz,
    lock_release_reason       varchar(500),
    verified_by               varchar(100),
    FOREIGN KEY (association_id, connector_id, container_id)
        REFERENCES docker_association (id, connector_id, container_id) ON DELETE CASCADE,
    CHECK (action <> 'STOP' OR protection_snapshot IS NOT NULL),
    CHECK ((state IN ('SUCCEEDED', 'FAILED')) = (completed_at IS NOT NULL)),
    CHECK ((lock_released_at IS NULL) = (lock_release_reason IS NULL)),
    CHECK (lock_released_at IS NULL OR (state = 'UNKNOWN' AND verified_by IS NOT NULL))
);
CREATE UNIQUE INDEX intervention_blocking_uq ON intervention (connector_id, container_id)
    WHERE state IN ('QUEUED', 'RUNNING') OR (state = 'UNKNOWN' AND lock_released_at IS NULL);
CREATE INDEX intervention_association_idx ON intervention (association_id, requested_at DESC);
CREATE INDEX intervention_dispatch_idx ON intervention (requested_at) WHERE state = 'QUEUED';

-- ============================================================ Énergie

CREATE TABLE energy_source (
    id                        uuid         PRIMARY KEY,
    device_identity           varchar(128) NOT NULL,
    kind                      text         NOT NULL CHECK (kind IN ('REAL', 'SIMULATED')),
    enabled                   boolean      NOT NULL DEFAULT false,
    address                   varchar(253),
    credential_protected      bytea,
    configured_at             timestamptz  NOT NULL,
    tariff_eur_per_kwh        numeric(6, 4) CHECK (tariff_eur_per_kwh BETWEEN 0 AND 10),
    max_power_w               numeric(8, 2) CHECK (max_power_w > 0 AND max_power_w < 'Infinity')
);
CREATE UNIQUE INDEX energy_source_enabled_uq ON energy_source (enabled) WHERE enabled;

CREATE TABLE energy_epoch (
    id                        uuid         PRIMARY KEY,
    source_id                 uuid         NOT NULL REFERENCES energy_source (id) ON DELETE RESTRICT,
    started_at                timestamptz  NOT NULL,
    ended_at                  timestamptz,
    reason                    text         NOT NULL CHECK (reason IN ('FIRST_REFERENCE', 'COUNTER_RESET', 'IDENTITY_CHANGED')),
    UNIQUE (id, source_id),
    CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE UNIQUE INDEX energy_epoch_current_uq ON energy_epoch (source_id) WHERE ended_at IS NULL;

CREATE TABLE energy_reading (
    id                        uuid         PRIMARY KEY,
    source_id                 uuid         NOT NULL REFERENCES energy_source (id) ON DELETE RESTRICT,
    epoch_id                  uuid,
    observed_at               timestamptz  NOT NULL,
    power_w                   numeric(10, 3) CHECK (power_w >= 0 AND power_w < 'Infinity'),
    total_wh                  numeric(14, 3) CHECK (total_wh >= 0 AND total_wh < 'Infinity'),
    quality                   text         NOT NULL CHECK (quality IN ('VALID', 'INVALID', 'ERROR')),
    error_code                varchar(64),
    UNIQUE (source_id, observed_at),
    UNIQUE (id, epoch_id),
    FOREIGN KEY (epoch_id, source_id) REFERENCES energy_epoch (id, source_id) ON DELETE RESTRICT,
    CHECK (quality <> 'VALID' OR (epoch_id IS NOT NULL AND power_w IS NOT NULL AND total_wh IS NOT NULL))
);
CREATE INDEX energy_reading_epoch_idx ON energy_reading (epoch_id) WHERE epoch_id IS NOT NULL;
CREATE INDEX energy_reading_purge_idx ON energy_reading (observed_at);

CREATE TABLE energy_interval (
    id                        uuid         PRIMARY KEY,
    source_id                 uuid         NOT NULL,
    epoch_id                  uuid         NOT NULL,
    start_reading_id          uuid         NOT NULL,
    end_reading_id            uuid         NOT NULL,
    start_at                  timestamptz  NOT NULL,
    end_at                    timestamptz  NOT NULL,
    delta_wh                  numeric(14, 3) NOT NULL CHECK (delta_wh >= 0 AND delta_wh < 'Infinity'),
    quality                   text         NOT NULL CHECK (quality IN ('VALID', 'IMPLAUSIBLE')),
    is_continuous             boolean      NOT NULL,
    UNIQUE (start_reading_id, end_reading_id),
    FOREIGN KEY (epoch_id, source_id) REFERENCES energy_epoch (id, source_id) ON DELETE RESTRICT,
    FOREIGN KEY (start_reading_id, epoch_id) REFERENCES energy_reading (id, epoch_id) ON DELETE RESTRICT,
    FOREIGN KEY (end_reading_id, epoch_id) REFERENCES energy_reading (id, epoch_id) ON DELETE RESTRICT,
    CHECK (start_reading_id <> end_reading_id),
    CHECK (end_at > start_at)
);
CREATE INDEX energy_interval_source_idx ON energy_interval (source_id, start_at);

-- ============================================================ Journalisation et santé

CREATE TABLE audit_event (
    id                        uuid         PRIMARY KEY,
    occurred_at               timestamptz  NOT NULL,
    actor_type                text         NOT NULL CHECK (actor_type IN ('ADMIN', 'SYSTEM', 'OPERATOR')),
    actor_id                  varchar(100),
    action                    varchar(100) NOT NULL,
    target_id                 uuid,
    outcome                   text         NOT NULL CHECK (outcome IN ('SUCCESS', 'FAILURE', 'DENIED')),
    correlation_id            varchar(64)
);
CREATE INDEX audit_event_occurred_idx ON audit_event (occurred_at);

CREATE TABLE worker_heartbeat (
    worker_id                 varchar(100) PRIMARY KEY,
    last_seen_at              timestamptz  NOT NULL,
    loop_lag_ms               integer      NOT NULL CHECK (loop_lag_ms >= 0),
    schema_version            varchar(32)  NOT NULL,
    status                    text         NOT NULL CHECK (status IN ('RUNNING', 'DEGRADED', 'STOPPING'))
);

COMMIT;
