-- =====================================================================
-- PITSTOP CORE - UNUSED INDEXES DIAGNOSTIC
-- Identificação de índices redundantes ou sem utilização via pg_stat_user_indexes
-- =====================================================================

SELECT
    schemaname,
    relname AS table_name,
    indexrelname AS index_name,
    idx_scan AS number_of_scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
JOIN pg_index USING (indexrelid)
WHERE idx_scan = 0
  AND NOT indisprimary
  AND NOT indisunique
ORDER BY pg_relation_size(indexrelid) DESC;
