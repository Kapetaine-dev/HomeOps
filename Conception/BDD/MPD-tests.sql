-- HomeOps — jeux d'essai du MPD : chaque contrainte est testée par une insertion valide et/ou invalide.
-- Usage : sur une base vide où MPD.sql vient d'être appliqué ; résultat attendu : 0 échec.
\set ON_ERROR_STOP 1
CREATE TEMP TABLE t_result (name text, ok boolean, detail text);

CREATE FUNCTION pg_temp.must_fail(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE stmt;
    INSERT INTO t_result VALUES (label, false, 'accepté à tort');
  EXCEPTION WHEN others THEN
    INSERT INTO t_result VALUES (label, true, SQLSTATE || ' ' || left(SQLERRM, 70));
  END;
END $$;

CREATE FUNCTION pg_temp.must_pass(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE stmt;
  INSERT INTO t_result VALUES (label, true, 'ok');
EXCEPTION WHEN others THEN
  INSERT INTO t_result VALUES (label, false, SQLSTATE || ' ' || left(SQLERRM, 70));
END $$;

-- Données de base
INSERT INTO instance_settings (id, schema_version) VALUES (1, '1');
INSERT INTO admin_account (id, login, normalized_login, password_hash, security_stamp, created_at)
  VALUES (1, 'Admin', 'admin', 'hash', gen_random_uuid(), now());
INSERT INTO service (id, name, normalized_name, address) VALUES
  ('00000000-0000-0000-0000-0000000000a1', 'Nas', 'nas', 'http://nas.lan'),
  ('00000000-0000-0000-0000-0000000000a2', 'Wiki', 'wiki', 'http://wiki.lan');
INSERT INTO probe (id, service_id, name, type, target, interval_seconds, timeout_seconds, expected_status, fail_threshold, success_threshold) VALUES
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000a1', 'web', 'HTTP', 'http://nas.lan', 60, 5, 200, 3, 2);
INSERT INTO probe (id, service_id, name, type, target, port, sni, interval_seconds, timeout_seconds, fail_threshold, success_threshold) VALUES
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-0000000000a1', 'cert', 'TLS', 'nas.lan', 443, 'nas.lan', 86400, 5, 3, 2);

-- Singletons
SELECT pg_temp.must_fail('SINGL paramètres id 2', $$INSERT INTO instance_settings (id, schema_version) VALUES (2, '1')$$);
SELECT pg_temp.must_fail('SINGL admin id 2', $$INSERT INTO admin_account VALUES (2, 'b', 'b', 'h', gen_random_uuid(), 0, NULL, now(), NULL)$$);
SELECT pg_temp.must_fail('Email avec CRLF', $$UPDATE instance_settings SET notification_email = E'a@b.fr\r\nBcc: x'$$);

-- Sessions
SELECT pg_temp.must_fail('Session ADMIN sans compte', $$INSERT INTO auth_session VALUES ('\x01', 'ADMIN', NULL, NULL, now(), now(), now(), now() + interval '12 hours', NULL)$$);
SELECT pg_temp.must_fail('Session KIOSK sans version', $$INSERT INTO auth_session VALUES ('\x02', 'KIOSK', NULL, NULL, now(), now(), now(), now() + interval '30 days', NULL)$$);
SELECT pg_temp.must_pass('Session KIOSK valide', $$INSERT INTO auth_session VALUES ('\x03', 'KIOSK', NULL, 'v1', now(), now(), now(), now() + interval '30 days', NULL)$$);

-- Services et sondes
SELECT pg_temp.must_fail('UNIQ nom de service', $$INSERT INTO service (id, name, normalized_name, address) VALUES (gen_random_uuid(), 'NAS', 'nas', 'x')$$);
SELECT pg_temp.must_fail('HTTP avec port', $$INSERT INTO probe (id, service_id, name, type, target, port, interval_seconds, timeout_seconds, expected_status, fail_threshold, success_threshold) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'x', 'HTTP', 'http://x', 80, 60, 5, 200, 3, 2)$$);
SELECT pg_temp.must_fail('TCP sans port', $$INSERT INTO probe (id, service_id, name, type, target, interval_seconds, timeout_seconds, fail_threshold, success_threshold) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'x', 'TCP', 'x', 60, 5, 3, 2)$$);
SELECT pg_temp.must_fail('HTTP intervalle 10 s', $$INSERT INTO probe (id, service_id, name, type, target, interval_seconds, timeout_seconds, expected_status, fail_threshold, success_threshold) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'x', 'HTTP', 'http://x', 10, 5, 200, 3, 2)$$);
SELECT pg_temp.must_fail('TLS intervalle 60 s', $$INSERT INTO probe (id, service_id, name, type, target, port, interval_seconds, timeout_seconds, fail_threshold, success_threshold) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'x', 'TLS', 'x', 443, 60, 5, 3, 2)$$);
SELECT pg_temp.must_fail('SNI sur HTTP', $$INSERT INTO probe (id, service_id, name, type, target, sni, interval_seconds, timeout_seconds, expected_status, fail_threshold, success_threshold) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'x', 'HTTP', 'http://x', 'x', 60, 5, 200, 3, 2)$$);
SELECT pg_temp.must_fail('Seuil 11', $$UPDATE probe SET fail_threshold = 11 WHERE type = 'HTTP'$$);

-- Résultats et contrôles immédiats
INSERT INTO probe_result (id, execution_id, probe_id, probe_revision, mode_revision, started_at, observed_at, duration_ms, outcome)
  VALUES ('00000000-0000-0000-0000-0000000000c1', gen_random_uuid(), '00000000-0000-0000-0000-0000000000b1', 1, 0, now(), now(), 12, 'FAIL');
SELECT pg_temp.must_fail('Résultat dupliqué (executionId)', $$INSERT INTO probe_result (id, execution_id, probe_id, probe_revision, mode_revision, started_at, observed_at, duration_ms, outcome) SELECT gen_random_uuid(), execution_id, probe_id, 1, 0, now(), now(), 1, 'PASS' FROM probe_result LIMIT 1$$);
SELECT pg_temp.must_pass('Contrôle immédiat', $$INSERT INTO check_request (id, probe_id, idempotency_key, requested_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000b1', gen_random_uuid(), now())$$);
SELECT pg_temp.must_fail('Deux contrôles actifs', $$INSERT INTO check_request (id, probe_id, idempotency_key, requested_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000b1', gen_random_uuid(), now())$$);

-- Incidents
INSERT INTO incident (id, probe_id, probe_revision, target_snapshot, type_snapshot, status, first_failure_at, opened_at)
  VALUES ('00000000-0000-0000-0000-0000000000d1', '00000000-0000-0000-0000-0000000000b1', 1, 'http://nas.lan', 'HTTP', 'OPEN', now(), now());
SELECT pg_temp.must_fail('CIF-1 deux incidents actifs', $$INSERT INTO incident (id, probe_id, probe_revision, target_snapshot, type_snapshot, status, first_failure_at, opened_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000b1', 1, 'x', 'HTTP', 'OPEN', now(), now())$$);
SELECT pg_temp.must_fail('ACK sans date', $$UPDATE incident SET status = 'ACKNOWLEDGED'$$);
SELECT pg_temp.must_fail('RESOLVED sans date', $$UPDATE incident SET status = 'RESOLVED'$$);
SELECT pg_temp.must_fail('CLOSED sans motif', $$UPDATE incident SET status = 'CLOSED', closed_at = now()$$);
SELECT pg_temp.must_fail('CLOSED avec resolved_at', $$UPDATE incident SET status = 'CLOSED', closed_at = now(), resolved_at = now(), closure_reason = 'CONFIGURATION_REPLACED'$$);
SELECT pg_temp.must_fail('Dates désordonnées', $$UPDATE incident SET status = 'RESOLVED', resolved_at = opened_at - interval '1 hour'$$);
SELECT pg_temp.must_fail('Note vide', $$INSERT INTO incident_note VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', now(), '')$$);
SELECT pg_temp.must_pass('Note valide', $$INSERT INTO incident_note VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000d1', now(), 'Redémarrage du NAS')$$);
SELECT pg_temp.must_pass('Clôture RESOLVED', $$UPDATE incident SET status = 'RESOLVED', resolved_at = now()$$);
SELECT pg_temp.must_pass('Nouvel incident après rétablissement', $$INSERT INTO incident (id, probe_id, probe_revision, target_snapshot, type_snapshot, status, first_failure_at, opened_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000b1', 1, 'x', 'HTTP', 'OPEN', now(), now())$$);

-- Notifications
SELECT pg_temp.must_pass('NOTIF TEST', $$INSERT INTO notification_outbox (id, event_key, recipient, type, created_at) VALUES (gen_random_uuid(), 'test-1', 'a@b.fr', 'TEST', now())$$);
SELECT pg_temp.must_fail('NOTIF TEST avec sonde', $$INSERT INTO notification_outbox (id, event_key, recipient, type, probe_id, created_at) VALUES (gen_random_uuid(), 'test-2', 'a@b.fr', 'TEST', '00000000-0000-0000-0000-0000000000b2', now())$$);
SELECT pg_temp.must_pass('NOTIF TLS', $$INSERT INTO notification_outbox (id, event_key, recipient, type, probe_id, created_at) VALUES (gen_random_uuid(), 'tls-1', 'a@b.fr', 'TLS_WARNING', '00000000-0000-0000-0000-0000000000b2', now())$$);
SELECT pg_temp.must_fail('NOTIF TLS sans sonde', $$INSERT INTO notification_outbox (id, event_key, recipient, type, created_at) VALUES (gen_random_uuid(), 'tls-2', 'a@b.fr', 'TLS_WARNING', now())$$);
SELECT pg_temp.must_pass('NOTIF ouverture', $$INSERT INTO notification_outbox (id, event_key, recipient, type, incident_id, created_at) VALUES (gen_random_uuid(), 'open-1', 'a@b.fr', 'INCIDENT_OPENED', '00000000-0000-0000-0000-0000000000d1', now())$$);
SELECT pg_temp.must_fail('NOTIF X sonde et incident', $$INSERT INTO notification_outbox (id, event_key, recipient, type, probe_id, incident_id, created_at) VALUES (gen_random_uuid(), 'open-2', 'a@b.fr', 'INCIDENT_OPENED', '00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-0000000000d1', now())$$);
SELECT pg_temp.must_fail('NOTIF doublon événement', $$INSERT INTO notification_outbox (id, event_key, recipient, type, incident_id, created_at) VALUES (gen_random_uuid(), 'open-1', 'a@b.fr', 'INCIDENT_OPENED', '00000000-0000-0000-0000-0000000000d1', now())$$);
SELECT pg_temp.must_fail('NOTIF 4 tentatives', $$UPDATE notification_outbox SET attempts = 4 WHERE event_key = 'open-1'$$);

-- Maintenance
SELECT pg_temp.must_pass('Maintenance 1 h', $$INSERT INTO maintenance VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', now(), now() + interval '1 hour', NULL, NULL)$$);
SELECT pg_temp.must_fail('CIF-2 deux maintenances actives', $$INSERT INTO maintenance VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', now(), now() + interval '1 hour', NULL, NULL)$$);
SELECT pg_temp.must_fail('Maintenance 1 min', $$INSERT INTO maintenance VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a2', now(), now() + interval '1 minute', NULL, NULL)$$);
SELECT pg_temp.must_fail('Maintenance 8 j', $$INSERT INTO maintenance VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a2', now(), now() + interval '8 days', NULL, NULL)$$);

-- Docker
INSERT INTO docker_association (id, service_id, connector_id, container_id, active_from)
  VALUES ('00000000-0000-0000-0000-0000000000e1', '00000000-0000-0000-0000-0000000000a1', 'host-1', repeat('a', 64), now());
SELECT pg_temp.must_fail('CIF-3 deux liaisons actives par service', $$INSERT INTO docker_association (id, service_id, connector_id, container_id, active_from) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a1', 'host-1', repeat('b', 64), now())$$);
SELECT pg_temp.must_fail('CIF-3 conteneur actif sur 2 services', $$INSERT INTO docker_association (id, service_id, connector_id, container_id, active_from) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a2', 'host-1', repeat('a', 64), now())$$);
SELECT pg_temp.must_fail('Identifiant conteneur court', $$INSERT INTO docker_association (id, service_id, connector_id, container_id, active_from) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000a2', 'host-1', 'abc', now())$$);
SELECT pg_temp.must_fail('Copie conteneur incohérente', $$INSERT INTO intervention (id, association_id, connector_id, container_id, idempotency_key, request_hash, action, requested_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000e1', 'host-1', repeat('c', 64), gen_random_uuid(), '\x00', 'START', now())$$);
SELECT pg_temp.must_fail('STOP sans protection', $$INSERT INTO intervention (id, association_id, connector_id, container_id, idempotency_key, request_hash, action, requested_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000e1', 'host-1', repeat('a', 64), gen_random_uuid(), '\x00', 'STOP', now())$$);
INSERT INTO intervention (id, association_id, connector_id, container_id, idempotency_key, request_hash, action, state, requested_at, dispatched_at)
  VALUES ('00000000-0000-0000-0000-0000000000f1', '00000000-0000-0000-0000-0000000000e1', 'host-1', repeat('a', 64), gen_random_uuid(), '\x00', 'RESTART', 'UNKNOWN', now(), now());
SELECT pg_temp.must_fail('CIF-4 UNKNOWN bloque', $$INSERT INTO intervention (id, association_id, connector_id, container_id, idempotency_key, request_hash, action, requested_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000e1', 'host-1', repeat('a', 64), gen_random_uuid(), '\x00', 'START', now())$$);
SELECT pg_temp.must_fail('Levée sans vérificateur', $$UPDATE intervention SET lock_released_at = now(), lock_release_reason = 'vérifié' WHERE id = '00000000-0000-0000-0000-0000000000f1'$$);
SELECT pg_temp.must_pass('Levée du verrou', $$UPDATE intervention SET lock_released_at = now(), lock_release_reason = 'vérifié', verified_by = 'exploitant' WHERE id = '00000000-0000-0000-0000-0000000000f1'$$);
SELECT pg_temp.must_pass('Nouvelle action après levée', $$INSERT INTO intervention (id, association_id, connector_id, container_id, idempotency_key, request_hash, action, requested_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000e1', 'host-1', repeat('a', 64), gen_random_uuid(), '\x00', 'START', now())$$);
SELECT pg_temp.must_fail('CIF-4 deux actions en file', $$INSERT INTO intervention (id, association_id, connector_id, container_id, idempotency_key, request_hash, action, requested_at) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-0000000000e1', 'host-1', repeat('a', 64), gen_random_uuid(), '\x00', 'START', now())$$);

-- Énergie
INSERT INTO energy_source (id, device_identity, kind, enabled, configured_at, max_power_w) VALUES
  ('00000000-0000-0000-0000-000000000011', 'shelly-1', 'SIMULATED', true, now(), 3500),
  ('00000000-0000-0000-0000-000000000012', 'shelly-2', 'REAL', false, now(), 3500);
SELECT pg_temp.must_fail('CIF-6 deux sources actives', $$UPDATE energy_source SET enabled = true WHERE id = '00000000-0000-0000-0000-000000000012'$$);
INSERT INTO energy_epoch VALUES ('00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000011', now(), NULL, 'FIRST_REFERENCE');
INSERT INTO energy_epoch VALUES ('00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000012', now(), NULL, 'FIRST_REFERENCE');
SELECT pg_temp.must_fail('CIF-6 deux époques courantes', $$INSERT INTO energy_epoch VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000011', now(), NULL, 'COUNTER_RESET')$$);
SELECT pg_temp.must_pass('Relevé en erreur sans époque', $$INSERT INTO energy_reading (id, source_id, observed_at, quality, error_code) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000011', now() - interval '1 hour', 'ERROR', 'TIMEOUT')$$);
SELECT pg_temp.must_fail('CIF-5 relevé valide sans époque', $$INSERT INTO energy_reading (id, source_id, observed_at, power_w, total_wh, quality) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000011', now(), 85, 12000, 'VALID')$$);
SELECT pg_temp.must_fail('CIF-5 époque d''une autre source', $$INSERT INTO energy_reading (id, source_id, epoch_id, observed_at, power_w, total_wh, quality) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000022', now(), 85, 12000, 'VALID')$$);
SELECT pg_temp.must_fail('Compteur NaN', $$INSERT INTO energy_reading (id, source_id, observed_at, total_wh, quality) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000011', now() - interval '2 hours', 'NaN', 'INVALID')$$);
SELECT pg_temp.must_fail('Compteur négatif', $$INSERT INTO energy_reading (id, source_id, observed_at, total_wh, quality) VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000011', now() - interval '3 hours', -5, 'INVALID')$$);
INSERT INTO energy_reading (id, source_id, epoch_id, observed_at, power_w, total_wh, quality) VALUES
  ('00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000021', now() - interval '60 seconds', 85, 12000, 'VALID'),
  ('00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000021', now(), 86, 12060, 'VALID');
SELECT pg_temp.must_fail('UNIQ relevé source/date', $$INSERT INTO energy_reading (id, source_id, epoch_id, observed_at, power_w, total_wh, quality) SELECT gen_random_uuid(), source_id, epoch_id, observed_at, 1, 1, 'VALID' FROM energy_reading WHERE id = '00000000-0000-0000-0000-000000000031'$$);
SELECT pg_temp.must_pass('Intervalle valide', $$INSERT INTO energy_interval VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000011', '00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000031', '00000000-0000-0000-0000-000000000032', now() - interval '60 seconds', now(), 60, 'VALID', true)$$);
SELECT pg_temp.must_fail('Intervalle hors époque', $$INSERT INTO energy_interval VALUES (gen_random_uuid(), '00000000-0000-0000-0000-000000000012', '00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000032', '00000000-0000-0000-0000-000000000031', now() - interval '60 seconds', now(), 60, 'VALID', true)$$);
SELECT pg_temp.must_fail('Purge relevé référencé', $$DELETE FROM energy_reading WHERE id = '00000000-0000-0000-0000-000000000031'$$);
SELECT pg_temp.must_fail('Purge époque référencée', $$DELETE FROM energy_epoch WHERE id = '00000000-0000-0000-0000-000000000021'$$);
SELECT pg_temp.must_fail('Suppression source référencée', $$DELETE FROM energy_source WHERE id = '00000000-0000-0000-0000-000000000011'$$);

-- Retrait de sonde : l'historique reste
SELECT pg_temp.must_pass('Retrait de sonde', $$UPDATE probe SET retired_at = now() WHERE id = '00000000-0000-0000-0000-0000000000b1'$$);

-- Cascade à la suppression du service (REQ-S06)
INSERT INTO audit_event VALUES (gen_random_uuid(), now(), 'ADMIN', NULL, 'service.delete', '00000000-0000-0000-0000-0000000000a1', 'SUCCESS', 'trace-1');
SELECT pg_temp.must_pass('Suppression du service', $$DELETE FROM service WHERE id = '00000000-0000-0000-0000-0000000000a1'$$);
INSERT INTO t_result SELECT 'Cascade complète',
  (SELECT count(*) FROM probe) + (SELECT count(*) FROM probe_result) + (SELECT count(*) FROM incident)
  + (SELECT count(*) FROM incident_note) + (SELECT count(*) FROM maintenance) + (SELECT count(*) FROM docker_association)
  + (SELECT count(*) FROM intervention) + (SELECT count(*) FROM check_request)
  + (SELECT count(*) FROM notification_outbox WHERE type <> 'TEST') = 0,
  'restes : ' || (SELECT count(*) FROM probe) || ' sondes, ' || (SELECT count(*) FROM incident) || ' incidents';
INSERT INTO t_result SELECT 'TEST et audit conservés',
  (SELECT count(*) FROM notification_outbox WHERE type = 'TEST') = 1 AND (SELECT count(*) FROM audit_event) = 1, '';

\pset footer off
SELECT ok, name, detail FROM t_result ORDER BY ok, name;
SELECT count(*) FILTER (WHERE ok) AS reussis, count(*) FILTER (WHERE NOT ok) AS echecs FROM t_result;
