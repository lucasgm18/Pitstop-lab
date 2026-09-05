-- =====================================================================
-- PITSTOP CORE - TABLE BLOAT & DEAD TUPLES DIAGNOSTIC
-- Inspeção de tuplas mortas, razão de bloat e atividade de autovacuum
-- =====================================================================

SELECT
    schemaname,
    relname AS table_name,
    n_live_tup AS live_tuples,
    n_dead_tup AS dead_tuples,
    ROUND(
        (n_dead_tup::numeric / NULLIF(n_live_tup + n_dead_tup, 0) * 100), 
        2
    ) AS dead_tuple_ratio_pct,
    pg_size_pretty(pg_relation_size(relid)) AS table_size,
    pg_size_pretty(pg_total_relation_size(relid)) AS total_size_with_indexes,
    last_vacuum,
    last_autovacuum,
    last_analyze,
    last_autoanalyze,
    vacuum_count,
    autovacuum_count
FROM pg_stat_user_tables
WHERE relname = COALESCE(:target_table, relname)
ORDER BY n_dead_tup DESC;
