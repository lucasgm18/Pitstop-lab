-- =====================================================================
-- PITSTOP CORE - ACTIVE SESSIONS & LOCK CONTENTION DIAGNOSTIC
-- Inspeção em tempo real de conexões ativas, bloqueios e transações longas
-- =====================================================================

SELECT
    a.pid,
    a.usename,
    a.client_addr,
    a.application_name,
    a.state,
    a.wait_event_type,
    a.wait_event,
    pg_blocking_pids(a.pid) AS blocking_pids,
    ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - a.xact_start))::numeric, 2) AS xact_duration_sec,
    ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - a.query_start))::numeric, 2) AS query_duration_sec,
    LEFT(REGEXP_REPLACE(a.query, '\s+', ' ', 'g'), 120) AS query_snippet
FROM pg_stat_activity a
WHERE a.pid <> pg_backend_pid()
  AND a.datname = current_database()
  AND (a.state = 'active' OR a.state = 'idle in transaction' OR array_length(pg_blocking_pids(a.pid), 1) > 0)
ORDER BY 
    array_length(pg_blocking_pids(a.pid), 1) DESC NULLS LAST,
    xact_duration_sec DESC NULLS LAST;
