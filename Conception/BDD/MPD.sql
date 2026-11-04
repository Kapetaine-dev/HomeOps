-- HomeOps — MPD v1.1 — PostgreSQL 17
-- Dérivé du MLD v1.1 (MLD.md). Référence du schéma : la configuration EF Core reprend ces types et ces noms
-- (HasConstraintName, HasDatabaseName) ; la première migration doit produire le même schéma (pg_dump -s).
-- Conventions : snake_case, uuid applicatifs, timestamptz (UTC), numeric pour les mesures, énumérations en text + CHECK.
-- Noms : pk_ clé primaire, fk_ clé étrangère, ak_ clé alternative, ix_ index (unique ou non), ck_ contrôle.

BEGIN;

-- ============================================================ Instance et accès

CREATE TABLE instance_settings (
    id                        smallint     NOT NULL,
    initialized_at            timestamptz,
    timezone                  varchar(64)  NOT NULL DEFAULT 'Europe/Paris',
    notification_email        varchar(254),
    theme_default             text         NOT NULL DEFAULT 'LIGHT',
    reduce_motion             boolean      NOT NULL DEFAULT false,
    default_interval_seconds  integer      NOT NULL DEFAULT 60,
    default_timeout_seconds   integer      NOT NULL DEFAULT 5,
    default_fail_threshold    smallint     NOT NULL DEFAULT 3,
    default_success_threshold smallint     NOT NULL DEFAULT 2,
    tls_warning_days          smallint     NOT NULL DEFAULT 30,
    CONSTRAINT pk_instance_settings PRIMARY KEY (id),
    CONSTRAINT ck_instance_settings_singleton CHECK (id = 1),
    CONSTRAINT ck_instance_settings_email CHECK (notification_email !~ '[\r\n]'),
    CONSTRAINT ck_instance_settings_theme CHECK (theme_default IN ('LIGHT', 'DARK', 'RED')),
    CONSTRAINT ck_instance_settings_interval CHECK (default_interval_seconds BETWEEN 30 AND 3600),
    CONSTRAINT ck_instance_settings_timeout CHECK (default_timeout_seconds BETWEEN 1 AND 15),
    CONSTRAINT ck_instance_settings_thresholds CHECK (default_fail_threshold BETWEEN 1 AND 10
                                                      AND default_success_threshold BETWEEN 1 AND 10),
    CONSTRAINT ck_instance_settings_tls_warning CHECK (tls_warning_days BETWEEN 1 AND 90)
);

CREATE TABLE admin_account (
    id                        smallint     NOT NULL,
    login                     varchar(80)  NOT NULL,
    normalized_login          varchar(80)  NOT NULL,
    password_hash             text         NOT NULL,
    failed_login_count        integer      NOT NULL DEFAULT 0,
    lockout_until             timestamptz,
    created_at                timestamptz  NOT NULL,
    last_successful_login_at  timestamptz,
    CONSTRAINT pk_admin_account PRIMARY KEY (id),
    CONSTRAINT ck_admin_account_singleton CHECK (id = 1),
    CONSTRAINT ck_admin_account_failed_count CHECK (failed_login_count >= 0)
);

CREATE TABLE auth_session (
    id_hash                   bytea        NOT NULL,
    principal_type            text         NOT NULL,
    admin_account_id          smallint,
    credential_version        varchar(64),
    created_at                timestamptz  NOT NULL,
    last_seen_at              timestamptz  NOT NULL,
    expires_at                timestamptz  NOT NULL,
    absolute_expires_at       timestamptz  NOT NULL,
    revoked_at                timestamptz,
    CONSTRAINT pk_auth_session PRIMARY KEY (id_hash),
    CONSTRAINT fk_auth_session_admin_account FOREIGN KEY (admin_account_id) REFERENCES admin_account (id) ON DELETE CASCADE,
    CONSTRAINT ck_auth_session_principal CHECK (principal_type IN ('ADMIN', 'KIOSK')),
    CONSTRAINT ck_auth_session_admin CHECK ((principal_type = 'ADMIN') = (admin_account_id IS NOT NULL)),
    CONSTRAINT ck_auth_session_kiosk CHECK ((principal_type = 'KIOSK') = (credential_version IS NOT NULL)),
    CONSTRAINT ck_auth_session_expiry CHECK (expires_at <= absolute_expires_at)
);
CREATE INDEX ix_auth_session_absolute_expires_at ON auth_session (absolute_expires_at);

-- ============================================================ Supervision

CREATE TABLE service (
    id                        uuid         NOT NULL,
    name                      varchar(80)  NOT NULL,
    normalized_name           varchar(80)  NOT NULL,
    address                   varchar(2048) NOT NULL,
    description               varchar(500),
    troubleshooting_notes     varchar(10000),
    mode                      text         NOT NULL DEFAULT 'NORMAL',
    mode_revision             integer      NOT NULL DEFAULT 0,
    CONSTRAINT pk_service PRIMARY KEY (id),
    CONSTRAINT ck_service_name CHECK (name <> ''),
    CONSTRAINT ck_service_address CHECK (address <> ''),
    CONSTRAINT ck_service_mode CHECK (mode IN ('NORMAL', 'MAINTENANCE', 'SUSPENDED'))
);
CREATE UNIQUE INDEX ix_service_normalized_name ON service (normalized_name);

CREATE TABLE probe (
    id                        uuid         NOT NULL,
    service_id                uuid         NOT NULL,
    name                      varchar(80)  NOT NULL,
    type                      text         NOT NULL,
    target                    varchar(2048) NOT NULL,
    port                      integer,
    sni                       varchar(253),
    interval_seconds          integer      NOT NULL,
    timeout_seconds           integer      NOT NULL,
    expected_status           smallint,
    fail_threshold            smallint     NOT NULL,
    success_threshold         smallint     NOT NULL,
    revision                  integer      NOT NULL DEFAULT 1,
    retired_at                timestamptz,
    next_due_at               timestamptz,
    CONSTRAINT pk_probe PRIMARY KEY (id),
    CONSTRAINT fk_probe_service FOREIGN KEY (service_id) REFERENCES service (id) ON DELETE CASCADE,
    CONSTRAINT ck_probe_name CHECK (name <> ''),
    CONSTRAINT ck_probe_type CHECK (type IN ('HTTP', 'TCP', 'TLS')),
    CONSTRAINT ck_probe_target CHECK (target <> ''),
    CONSTRAINT ck_probe_port CHECK ((type = 'HTTP') = (port IS NULL) AND (port IS NULL OR port BETWEEN 1 AND 65535)),
    CONSTRAINT ck_probe_expected_status CHECK ((type = 'HTTP') = (expected_status IS NOT NULL)
                                               AND (expected_status IS NULL OR expected_status BETWEEN 100 AND 599)),
    CONSTRAINT ck_probe_sni CHECK (sni IS NULL OR type = 'TLS'),
    CONSTRAINT ck_probe_interval CHECK (CASE type WHEN 'TLS' THEN interval_seconds BETWEEN 3600 AND 86400
                                                  ELSE interval_seconds BETWEEN 30 AND 3600 END),
    CONSTRAINT ck_probe_timeout CHECK (timeout_seconds BETWEEN 1 AND 15 AND interval_seconds > timeout_seconds),
    CONSTRAINT ck_probe_thresholds CHECK (fail_threshold BETWEEN 1 AND 10 AND success_threshold BETWEEN 1 AND 10)
);
CREATE INDEX ix_probe_service_id ON probe (service_id);
CREATE INDEX ix_probe_next_due_at ON probe (next_due_at) WHERE retired_at IS NULL;

CREATE TABLE probe_result (
    id                        uuid         NOT NULL,
    execution_id              uuid         NOT NULL,
    probe_id                  uuid         NOT NULL,
    probe_revision            integer      NOT NULL,
    mode_revision             integer      NOT NULL,
    started_at                timestamptz  NOT NULL,
    observed_at               timestamptz  NOT NULL,
    duration_ms               integer      NOT NULL,
    outcome                   text         NOT NULL,
    error_code                varchar(64),
    http_status               smallint,
    tls_not_after             timestamptz,
    fingerprint               varchar(128),
    CONSTRAINT pk_probe_result PRIMARY KEY (id),
    CONSTRAINT fk_probe_result_probe FOREIGN KEY (probe_id) REFERENCES probe (id) ON DELETE CASCADE,
    CONSTRAINT ck_probe_result_outcome CHECK (outcome IN ('PASS', 'FAIL', 'ERROR_INTERNAL')),
    CONSTRAINT ck_probe_result_duration CHECK (duration_ms >= 0 AND observed_at >= started_at),
    CONSTRAINT ck_probe_result_http_status CHECK (http_status BETWEEN 100 AND 599)
);
CREATE UNIQUE INDEX ix_probe_result_execution_id ON probe_result (execution_id);
CREATE INDEX ix_probe_result_probe_id_observed_at ON probe_result (probe_id, observed_at DESC);

CREATE TABLE probe_state (
    probe_id                  uuid         NOT NULL,
    fail_streak               integer      NOT NULL DEFAULT 0,
    success_streak            integer      NOT NULL DEFAULT 0,
    first_failure_at          timestamptz,
    last_applied_result_id    uuid,
    health_state              text         NOT NULL DEFAULT 'UNKNOWN',
    tls_episode_fingerprint   varchar(128),
    tls_episode_started_at    timestamptz,
    tls_notified_at           timestamptz,
    CONSTRAINT pk_probe_state PRIMARY KEY (probe_id),
    CONSTRAINT fk_probe_state_probe FOREIGN KEY (probe_id) REFERENCES probe (id) ON DELETE CASCADE,
    CONSTRAINT fk_probe_state_last_result FOREIGN KEY (last_applied_result_id) REFERENCES probe_result (id) ON DELETE SET NULL,
    CONSTRAINT ck_probe_state_streaks CHECK (fail_streak >= 0 AND success_streak >= 0),
    CONSTRAINT ck_probe_state_health CHECK (health_state IN ('UNKNOWN', 'UP', 'DOWN')),
    CONSTRAINT ck_probe_state_tls_episode CHECK ((tls_episode_fingerprint IS NULL) = (tls_episode_started_at IS NULL))
);
CREATE INDEX ix_probe_state_last_applied_result_id ON probe_state (last_applied_result_id) WHERE last_applied_result_id IS NOT NULL;

CREATE TABLE check_request (
    id                        uuid         NOT NULL,
    probe_id                  uuid         NOT NULL,
    idempotency_key           uuid         NOT NULL,
    requested_at              timestamptz  NOT NULL,
    state                     text         NOT NULL DEFAULT 'PENDING',
    result_id                 uuid,
    CONSTRAINT pk_check_request PRIMARY KEY (id),
    CONSTRAINT fk_check_request_probe FOREIGN KEY (probe_id) REFERENCES probe (id) ON DELETE CASCADE,
    CONSTRAINT fk_check_request_result FOREIGN KEY (result_id) REFERENCES probe_result (id) ON DELETE SET NULL,
    CONSTRAINT ck_check_request_state CHECK (state IN ('PENDING', 'RUNNING', 'DONE', 'FAILED'))
);
CREATE UNIQUE INDEX ix_check_request_idempotency_key ON check_request (idempotency_key);
CREATE UNIQUE INDEX ix_check_request_active ON check_request (probe_id) WHERE state IN ('PENDING', 'RUNNING');
CREATE INDEX ix_check_request_result_id ON check_request (result_id) WHERE result_id IS NOT NULL;

-- ============================================================ Incidents et notifications

CREATE TABLE incident (
    id                        uuid         NOT NULL,
    probe_id                  uuid         NOT NULL,
    probe_revision            integer      NOT NULL,
    target_snapshot           varchar(2048) NOT NULL,
    type_snapshot             text         NOT NULL,
    status                    text         NOT NULL,
    first_failure_at          timestamptz  NOT NULL,
    opened_at                 timestamptz  NOT NULL,
    acknowledged_at           timestamptz,
    resolved_at               timestamptz,
    closed_at                 timestamptz,
    closure_reason            text,
    CONSTRAINT pk_incident PRIMARY KEY (id),
    CONSTRAINT fk_incident_probe FOREIGN KEY (probe_id) REFERENCES probe (id) ON DELETE CASCADE,
    CONSTRAINT ck_incident_type_snapshot CHECK (type_snapshot IN ('HTTP', 'TCP', 'TLS')),
    CONSTRAINT ck_incident_status CHECK (status IN ('OPEN', 'ACKNOWLEDGED', 'RESOLVED', 'CLOSED')),
    CONSTRAINT ck_incident_active CHECK (status NOT IN ('OPEN', 'ACKNOWLEDGED') OR (resolved_at IS NULL AND closed_at IS NULL)),
    CONSTRAINT ck_incident_open CHECK (status <> 'OPEN' OR acknowledged_at IS NULL),
    CONSTRAINT ck_incident_acknowledged CHECK (status <> 'ACKNOWLEDGED' OR acknowledged_at IS NOT NULL),
    CONSTRAINT ck_incident_resolved CHECK ((status = 'RESOLVED') = (resolved_at IS NOT NULL)),
    CONSTRAINT ck_incident_closed CHECK ((status = 'CLOSED') = (closed_at IS NOT NULL)
                                         AND (status = 'CLOSED') = (closure_reason IS NOT NULL)),
    CONSTRAINT ck_incident_closure_reason CHECK (closure_reason IN ('CONFIGURATION_REPLACED')),
    CONSTRAINT ck_incident_dates CHECK (first_failure_at <= opened_at
                                        AND (acknowledged_at IS NULL OR acknowledged_at >= opened_at)
                                        AND (resolved_at IS NULL OR resolved_at >= opened_at)
                                        AND (closed_at IS NULL OR closed_at >= opened_at))
);
CREATE UNIQUE INDEX ix_incident_active ON incident (probe_id) WHERE status IN ('OPEN', 'ACKNOWLEDGED');
CREATE INDEX ix_incident_probe_id ON incident (probe_id, opened_at DESC);

CREATE TABLE incident_note (
    id                        uuid         NOT NULL,
    incident_id               uuid         NOT NULL,
    created_at                timestamptz  NOT NULL,
    text                      varchar(4000) NOT NULL,
    CONSTRAINT pk_incident_note PRIMARY KEY (id),
    CONSTRAINT fk_incident_note_incident FOREIGN KEY (incident_id) REFERENCES incident (id) ON DELETE CASCADE,
    CONSTRAINT ck_incident_note_text CHECK (text <> '')
);
CREATE INDEX ix_incident_note_incident_id ON incident_note (incident_id, created_at);

CREATE TABLE notification_outbox (
    id                        uuid         NOT NULL,
    event_key                 varchar(200) NOT NULL,
    recipient                 varchar(254) NOT NULL,
    type                      text         NOT NULL,
    probe_id                  uuid,
    incident_id               uuid,
    state                     text         NOT NULL DEFAULT 'PENDING',
    attempts                  smallint     NOT NULL DEFAULT 0,
    next_attempt_at           timestamptz,
    message_id                varchar(255),
    last_error                varchar(500),
    created_at                timestamptz  NOT NULL,
    CONSTRAINT pk_notification_outbox PRIMARY KEY (id),
    CONSTRAINT fk_notification_outbox_probe FOREIGN KEY (probe_id) REFERENCES probe (id) ON DELETE CASCADE,
    CONSTRAINT fk_notification_outbox_incident FOREIGN KEY (incident_id) REFERENCES incident (id) ON DELETE CASCADE,
    CONSTRAINT ck_notification_outbox_recipient CHECK (recipient !~ '[\r\n]'),
    CONSTRAINT ck_notification_outbox_type CHECK (type IN ('INCIDENT_OPENED', 'INCIDENT_RESOLVED', 'TLS_WARNING', 'TEST')),
    CONSTRAINT ck_notification_outbox_target CHECK (CASE type
                 WHEN 'TEST'        THEN probe_id IS NULL     AND incident_id IS NULL
                 WHEN 'TLS_WARNING' THEN probe_id IS NOT NULL AND incident_id IS NULL
                 ELSE                    probe_id IS NULL     AND incident_id IS NOT NULL END),
    CONSTRAINT ck_notification_outbox_state CHECK (state IN ('PENDING', 'SENT', 'FAILED', 'UNKNOWN', 'CANCELED')),
    CONSTRAINT ck_notification_outbox_pending CHECK (state <> 'PENDING' OR next_attempt_at IS NOT NULL),
    CONSTRAINT ck_notification_outbox_attempts CHECK (attempts BETWEEN 0 AND 3)
);
CREATE UNIQUE INDEX ix_notification_outbox_event_key_recipient ON notification_outbox (event_key, recipient);
CREATE INDEX ix_notification_outbox_dispatch ON notification_outbox (state, next_attempt_at);
CREATE INDEX ix_notification_outbox_probe_id ON notification_outbox (probe_id) WHERE probe_id IS NOT NULL;
CREATE INDEX ix_notification_outbox_incident_id ON notification_outbox (incident_id) WHERE incident_id IS NOT NULL;

-- ============================================================ Exploitation

CREATE TABLE maintenance (
    id                        uuid         NOT NULL,
    service_id                uuid         NOT NULL,
    started_at                timestamptz  NOT NULL,
    ends_at                   timestamptz  NOT NULL,
    ended_at                  timestamptz,
    reason                    varchar(500),
    CONSTRAINT pk_maintenance PRIMARY KEY (id),
    CONSTRAINT fk_maintenance_service FOREIGN KEY (service_id) REFERENCES service (id) ON DELETE CASCADE,
    CONSTRAINT ck_maintenance_duration CHECK (ends_at - started_at BETWEEN interval '5 minutes' AND interval '7 days'),
    CONSTRAINT ck_maintenance_ended CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE UNIQUE INDEX ix_maintenance_active ON maintenance (service_id) WHERE ended_at IS NULL;
CREATE INDEX ix_maintenance_service_id ON maintenance (service_id, started_at DESC);

CREATE TABLE docker_association (
    id                        uuid         NOT NULL,
    service_id                uuid         NOT NULL,
    connector_id              varchar(100) NOT NULL,
    container_id              varchar(64)  NOT NULL,
    revision                  integer      NOT NULL DEFAULT 1,
    active_from               timestamptz  NOT NULL,
    inactive_at               timestamptz,
    last_state                text,
    last_observed_at          timestamptz,
    CONSTRAINT pk_docker_association PRIMARY KEY (id),
    CONSTRAINT ak_docker_association_container UNIQUE (id, connector_id, container_id),
    CONSTRAINT fk_docker_association_service FOREIGN KEY (service_id) REFERENCES service (id) ON DELETE CASCADE,
    CONSTRAINT ck_docker_association_container_id CHECK (container_id ~ '^[0-9a-f]{64}$'),
    CONSTRAINT ck_docker_association_last_state CHECK (last_state IN ('created', 'running', 'paused', 'restarting',
                                                                      'removing', 'exited', 'dead', 'unknown')),
    CONSTRAINT ck_docker_association_validity CHECK (inactive_at IS NULL OR inactive_at >= active_from)
);
CREATE UNIQUE INDEX ix_docker_association_service_active ON docker_association (service_id) WHERE inactive_at IS NULL;
CREATE UNIQUE INDEX ix_docker_association_container_active ON docker_association (connector_id, container_id) WHERE inactive_at IS NULL;

CREATE TABLE intervention (
    id                        uuid         NOT NULL,
    association_id            uuid         NOT NULL,
    connector_id              varchar(100) NOT NULL,
    container_id              varchar(64)  NOT NULL,
    idempotency_key           uuid         NOT NULL,
    request_hash              bytea        NOT NULL,
    action                    text         NOT NULL,
    protection_snapshot       text,
    state                     text         NOT NULL DEFAULT 'QUEUED',
    requested_at              timestamptz  NOT NULL,
    dispatched_at             timestamptz,
    completed_at              timestamptz,
    result_code               varchar(64),
    lock_released_at          timestamptz,
    lock_release_reason       varchar(500),
    verified_by               varchar(100),
    CONSTRAINT pk_intervention PRIMARY KEY (id),
    CONSTRAINT fk_intervention_association FOREIGN KEY (association_id, connector_id, container_id)
        REFERENCES docker_association (id, connector_id, container_id) ON DELETE CASCADE,
    CONSTRAINT ck_intervention_action CHECK (action IN ('START', 'STOP', 'RESTART')),
    CONSTRAINT ck_intervention_protection CHECK (CASE WHEN protection_snapshot IS NULL THEN action <> 'STOP'
                                                      ELSE protection_snapshot IN ('MAINTENANCE', 'SUSPENDED') END),
    CONSTRAINT ck_intervention_state CHECK (state IN ('QUEUED', 'RUNNING', 'SUCCEEDED', 'FAILED', 'UNKNOWN')),
    CONSTRAINT ck_intervention_completed CHECK ((state IN ('SUCCEEDED', 'FAILED')) = (completed_at IS NOT NULL)),
    CONSTRAINT ck_intervention_lock_release CHECK ((lock_released_at IS NULL) = (lock_release_reason IS NULL)
                                                   AND (lock_released_at IS NULL OR (state = 'UNKNOWN' AND verified_by IS NOT NULL)))
);
CREATE UNIQUE INDEX ix_intervention_idempotency_key ON intervention (idempotency_key);
CREATE UNIQUE INDEX ix_intervention_blocking ON intervention (connector_id, container_id)
    WHERE state IN ('QUEUED', 'RUNNING') OR (state = 'UNKNOWN' AND lock_released_at IS NULL);
CREATE INDEX ix_intervention_association_id ON intervention (association_id, requested_at DESC);
CREATE INDEX ix_intervention_queued ON intervention (requested_at) WHERE state = 'QUEUED';

-- ============================================================ Énergie

CREATE TABLE energy_source (
    id                        uuid         NOT NULL,
    device_identity           varchar(128) NOT NULL,
    kind                      text         NOT NULL,
    enabled                   boolean      NOT NULL DEFAULT false,
    address                   varchar(253),
    credential_protected      bytea,
    configured_at             timestamptz  NOT NULL,
    tariff_eur_per_kwh        numeric(6, 4),
    max_power_w               numeric(8, 2),
    CONSTRAINT pk_energy_source PRIMARY KEY (id),
    CONSTRAINT ck_energy_source_kind CHECK (kind IN ('REAL', 'SIMULATED')),
    CONSTRAINT ck_energy_source_tariff CHECK (tariff_eur_per_kwh BETWEEN 0 AND 10),
    CONSTRAINT ck_energy_source_max_power CHECK (max_power_w > 0 AND max_power_w < 'Infinity')
);
CREATE UNIQUE INDEX ix_energy_source_enabled ON energy_source (enabled) WHERE enabled;

CREATE TABLE energy_epoch (
    id                        uuid         NOT NULL,
    source_id                 uuid         NOT NULL,
    started_at                timestamptz  NOT NULL,
    ended_at                  timestamptz,
    reason                    text         NOT NULL,
    CONSTRAINT pk_energy_epoch PRIMARY KEY (id),
    CONSTRAINT ak_energy_epoch_source UNIQUE (id, source_id),
    CONSTRAINT fk_energy_epoch_source FOREIGN KEY (source_id) REFERENCES energy_source (id) ON DELETE RESTRICT,
    CONSTRAINT ck_energy_epoch_reason CHECK (reason IN ('FIRST_REFERENCE', 'COUNTER_RESET', 'IDENTITY_CHANGED')),
    CONSTRAINT ck_energy_epoch_dates CHECK (ended_at IS NULL OR ended_at >= started_at)
);
CREATE UNIQUE INDEX ix_energy_epoch_current ON energy_epoch (source_id) WHERE ended_at IS NULL;

CREATE TABLE energy_reading (
    id                        uuid         NOT NULL,
    source_id                 uuid         NOT NULL,
    epoch_id                  uuid,
    observed_at               timestamptz  NOT NULL,
    power_w                   numeric(10, 3),
    total_wh                  numeric(14, 3),
    quality                   text         NOT NULL,
    error_code                varchar(64),
    CONSTRAINT pk_energy_reading PRIMARY KEY (id),
    CONSTRAINT fk_energy_reading_source FOREIGN KEY (source_id) REFERENCES energy_source (id) ON DELETE RESTRICT,
    CONSTRAINT fk_energy_reading_epoch FOREIGN KEY (epoch_id, source_id)
        REFERENCES energy_epoch (id, source_id) ON DELETE RESTRICT,
    CONSTRAINT ck_energy_reading_values CHECK (power_w >= 0 AND power_w < 'Infinity'
                                               AND total_wh >= 0 AND total_wh < 'Infinity'),
    CONSTRAINT ck_energy_reading_quality CHECK (quality IN ('VALID', 'INVALID', 'ERROR')),
    CONSTRAINT ck_energy_reading_valid CHECK (quality <> 'VALID'
                                              OR (epoch_id IS NOT NULL AND power_w IS NOT NULL AND total_wh IS NOT NULL))
);
CREATE UNIQUE INDEX ix_energy_reading_source_id_observed_at ON energy_reading (source_id, observed_at);
CREATE INDEX ix_energy_reading_epoch_id ON energy_reading (epoch_id) WHERE epoch_id IS NOT NULL;

CREATE TABLE energy_interval (
    id                        uuid         NOT NULL,
    source_id                 uuid         NOT NULL,
    epoch_id                  uuid         NOT NULL,
    start_reading_id          uuid         NOT NULL,
    end_reading_id            uuid         NOT NULL,
    start_at                  timestamptz  NOT NULL,
    end_at                    timestamptz  NOT NULL,
    delta_wh                  numeric(14, 3) NOT NULL,
    quality                   text         NOT NULL,
    is_continuous             boolean      NOT NULL,
    CONSTRAINT pk_energy_interval PRIMARY KEY (id),
    CONSTRAINT fk_energy_interval_epoch FOREIGN KEY (epoch_id, source_id)
        REFERENCES energy_epoch (id, source_id) ON DELETE RESTRICT,
    CONSTRAINT fk_energy_interval_start FOREIGN KEY (start_reading_id) REFERENCES energy_reading (id) ON DELETE RESTRICT,
    CONSTRAINT fk_energy_interval_end FOREIGN KEY (end_reading_id) REFERENCES energy_reading (id) ON DELETE RESTRICT,
    CONSTRAINT ck_energy_interval_delta CHECK (delta_wh >= 0 AND delta_wh < 'Infinity'),
    CONSTRAINT ck_energy_interval_quality CHECK (quality IN ('VALID', 'IMPLAUSIBLE')),
    CONSTRAINT ck_energy_interval_bounds CHECK (start_reading_id <> end_reading_id AND end_at > start_at)
);
CREATE UNIQUE INDEX ix_energy_interval_readings ON energy_interval (start_reading_id, end_reading_id);
CREATE INDEX ix_energy_interval_end_reading_id ON energy_interval (end_reading_id);
CREATE INDEX ix_energy_interval_source_id ON energy_interval (source_id, start_at);

-- ============================================================ Journalisation et santé

CREATE TABLE audit_event (
    id                        uuid         NOT NULL,
    occurred_at               timestamptz  NOT NULL,
    actor_type                text         NOT NULL,
    actor_id                  varchar(100),
    action                    varchar(100) NOT NULL,
    target_id                 uuid,
    outcome                   text         NOT NULL,
    correlation_id            varchar(64),
    CONSTRAINT pk_audit_event PRIMARY KEY (id),
    CONSTRAINT ck_audit_event_actor CHECK (actor_type IN ('ADMIN', 'SYSTEM', 'OPERATOR')),
    CONSTRAINT ck_audit_event_outcome CHECK (outcome IN ('SUCCESS', 'FAILURE', 'DENIED'))
);
CREATE INDEX ix_audit_event_occurred_at ON audit_event (occurred_at);

CREATE TABLE worker_heartbeat (
    worker_id                 varchar(100) NOT NULL,
    last_seen_at              timestamptz  NOT NULL,
    loop_lag_ms               integer      NOT NULL,
    schema_version            varchar(32)  NOT NULL,
    status                    text         NOT NULL,
    CONSTRAINT pk_worker_heartbeat PRIMARY KEY (worker_id),
    CONSTRAINT ck_worker_heartbeat_lag CHECK (loop_lag_ms >= 0),
    CONSTRAINT ck_worker_heartbeat_status CHECK (status IN ('RUNNING', 'DEGRADED', 'STOPPING'))
);

COMMIT;
