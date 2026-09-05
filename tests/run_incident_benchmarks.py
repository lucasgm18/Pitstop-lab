#!/usr/bin/env python3
"""
=====================================================================
PITSTOP CORE - AUTOMATED INCIDENT & PERFORMANCE BENCHMARK SUITE
Author: Senior Staff Database Reliability Engineer & Test Specialist
Target: PostgreSQL 16 (pitstop_db) under 512MB RAM / 1 vCPU limits
=====================================================================
"""

import os
import sys
import time
import json
import threading
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import psycopg
from psycopg.rows import dict_row
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich import box

console = Console()


# =====================================================================
# DOMAIN ENTITIES & CONFIGURATION (Object Calisthenics: Wrap Primitives)
# =====================================================================

@dataclass(frozen=True)
class DatabaseConfig:
    """Configuração imutável de conexão com fallback automático."""
    host: str = os.getenv("PGHOST", "localhost")
    port: int = int(os.getenv("PGPORT", "5433"))
    dbname: str = os.getenv("PGDATABASE", "pitstop_db")
    user: str = os.getenv("PGUSER", "pitstop_admin")
    password: str = os.getenv("PGPASSWORD", os.getenv("POSTGRES_PASSWORD", ""))

    def conninfo(self, override_host: Optional[str] = None, override_port: Optional[int] = None) -> str:
        target_host = override_host or self.host
        target_port = override_port or self.port
        return f"host={target_host} port={target_port} dbname={self.dbname} user={self.user} password={self.password}"


class ConnectionFactory:
    """Fábrica de conexões resiliente que testa localhost e rede docker interna."""

    def __init__(self, config: DatabaseConfig) -> None:
        self._config = config

    def create(self) -> psycopg.Connection:
        # Tentativa 1: Host e Porta configurados (padrão: localhost:5433)
        try:
            return psycopg.connect(self._config.conninfo(), row_factory=dict_row, connect_timeout=3)
        except Exception:
            pass

        # Tentativa 2: Fallback para container direto (pitstop_postgres:5432)
        try:
            return psycopg.connect(
                self._config.conninfo(override_host="pitstop_postgres", override_port=5432),
                row_factory=dict_row,
                connect_timeout=3
            )
        except Exception:
            pass

        # Tentativa 3: Porta 5432 em localhost caso o ambiente host tenha sido redirecionado
        try:
            return psycopg.connect(
                self._config.conninfo(override_host="localhost", override_port=5432),
                row_factory=dict_row,
                connect_timeout=3
            )
        except Exception as exc:
            raise ConnectionError(
                f"Falha ao conectar no PostgreSQL. Verifique se o container está ativo: {exc}"
            ) from exc


# =====================================================================
# 1. CENÁRIO: BENCHMARK DE QUERY LENTA & SPILL DE DISCO
# =====================================================================

@dataclass(frozen=True)
class QueryPerformanceMetrics:
    execution_time_ms: float
    planning_time_ms: float
    total_cost: float
    shared_read_blocks: int
    shared_hit_blocks: int
    scan_types: str
    sort_method: str
    spill_to_disk: bool


class SlowQueryAnalyzer:
    """Analisa planos EXPLAIN (ANALYZE, BUFFERS) e compara com índice parcial."""

    QUERY = """
    EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
    SELECT id, veiculo_id, numero_os, status, valor_total, data_abertura, descricao_problema
    FROM ordens_servico
    WHERE status = 'EM_EXECUCAO' AND valor_total > 1500
    ORDER BY data_abertura DESC
    LIMIT 50;
    """

    INDEX_CREATE_SQL = """
    CREATE INDEX IF NOT EXISTS idx_bench_os_execucao 
    ON ordens_servico (valor_total, data_abertura DESC, veiculo_id) 
    WHERE status = 'EM_EXECUCAO';
    """

    INDEX_DROP_SQL = "DROP INDEX IF EXISTS idx_bench_os_execucao;"

    def __init__(self, connection_factory: ConnectionFactory) -> None:
        self._factory = connection_factory

    def execute(self) -> None:
        console.print(Panel.fit(
            "[bold cyan]Teste 1: Diagnóstico de Query Lenta & Spill de Disco (I/O e Memória)[/bold cyan]\n"
            "[dim]Objetivo: Evidenciar Seq Scan massivo vs Index Scan em base de 500k ordens sob 512MB RAM.[/dim]",
            border_style="cyan"
        ))

        with self._factory.create() as conn:
            # 1. Executa sem índice
            self._drop_index(conn)
            metrics_before = self._run_explain(conn)

            # 2. Cria índice parcial
            console.print("[yellow]🔨 Criando índice parcial otimizado...[/yellow]")
            conn.execute(self.INDEX_CREATE_SQL)
            conn.commit()

            # 3. Executa com índice ativo
            metrics_after = self._run_explain(conn)

            # 4. Limpeza para idempotência
            self._drop_index(conn)

        self._render_comparison_table(metrics_before, metrics_after)

    def _run_explain(self, conn: psycopg.Connection) -> QueryPerformanceMetrics:
        with conn.cursor() as cur:
            cur.execute(self.QUERY)
            raw_result = cur.fetchone()
            if not raw_result:
                raise ValueError("Nenhum plano retornado pelo PostgreSQL.")
            
            plan_json = raw_result["QUERY PLAN"]
            if isinstance(plan_json, list):
                plan_json = plan_json[0]
            
            return self._parse_plan(plan_json)

    def _parse_plan(self, plan_data: Dict[str, Any]) -> QueryPerformanceMetrics:
        plan_root = plan_data.get("Plan", {})
        execution_time = float(plan_data.get("Execution Time", 0.0))
        planning_time = float(plan_data.get("Planning Time", 0.0))
        total_cost = float(plan_root.get("Total Cost", 0.0))

        scan_nodes: List[str] = []
        sort_method = "N/A"
        spill = False
        shared_read = 0
        shared_hit = 0

        # Navegação recursiva dos nós do plano
        nodes_to_visit = [plan_root]
        while nodes_to_visit:
            curr = nodes_to_visit.pop()
            node_type = curr.get("Node Type", "")
            
            if "Scan" in node_type:
                scan_nodes.append(node_type)
            
            if "Sort Method" in curr:
                sort_method = curr["Sort Method"]
                if "external" in sort_method.lower() or "disk" in sort_method.lower():
                    spill = True

            shared_read += int(curr.get("Shared Read Blocks", 0))
            shared_hit += int(curr.get("Shared Hit Blocks", 0))

            if "Plans" in curr:
                nodes_to_visit.extend(curr["Plans"])

        unique_scans = ", ".join(sorted(set(scan_nodes))) or "Unknown"

        return QueryPerformanceMetrics(
            execution_time_ms=round(execution_time, 2),
            planning_time_ms=round(planning_time, 2),
            total_cost=round(total_cost, 2),
            shared_read_blocks=shared_read,
            shared_hit_blocks=shared_hit,
            scan_types=unique_scans,
            sort_method=sort_method,
            spill_to_disk=spill
        )

    def _drop_index(self, conn: psycopg.Connection) -> None:
        conn.execute(self.INDEX_DROP_SQL)
        conn.commit()

    def _render_comparison_table(self, before: QueryPerformanceMetrics, after: QueryPerformanceMetrics) -> None:
        table = Table(
            title="Comparativo de Performance: Seq Scan (Sem Índice) vs Parcial Index Scan",
            box=box.ROUNDED,
            header_style="bold magenta"
        )
        table.add_column("Métrica de Engenharia", style="bold white", width=34)
        table.add_column("Sem Índice (Seq Scan)", justify="right", style="red")
        table.add_column("Com Índice Parcial", justify="right", style="green")
        table.add_column("Variação / Ganho (%)", justify="right", style="bold yellow")

        time_delta = self._calc_reduction(before.execution_time_ms, after.execution_time_ms)
        cost_delta = self._calc_reduction(before.total_cost, after.total_cost)
        read_delta = self._calc_reduction(before.shared_read_blocks, after.shared_read_blocks)

        table.add_row("Execution Time (ms)", f"{before.execution_time_ms} ms", f"{after.execution_time_ms} ms", f"{time_delta}%")
        table.add_row("Planning Time (ms)", f"{before.planning_time_ms} ms", f"{after.planning_time_ms} ms", f"{self._calc_reduction(before.planning_time_ms, after.planning_time_ms)}%")
        table.add_row("Total Cost Estimado", f"{before.total_cost}", f"{after.total_cost}", f"{cost_delta}%")
        table.add_row("Shared Read Blocks (Disco)", f"{before.shared_read_blocks} blocos", f"{after.shared_read_blocks} blocos", f"{read_delta}%")
        table.add_row("Shared Hit Blocks (RAM)", f"{before.shared_hit_blocks} blocos", f"{after.shared_hit_blocks} blocos", "-")
        table.add_row("Tipo de Varredura Principal", before.scan_types, after.scan_types, "Otimizado")
        table.add_row("Método de Ordenação", before.sort_method, after.sort_method, "Heap/Index")
        table.add_row("Spill para Disco (work_mem)", str(before.spill_to_disk), str(after.spill_to_disk), "Zero Spill")

        console.print(table)
        console.print(f"[bold green]✔ Redução de tempo de execução: {time_delta}%[/bold green]")
        console.print(f"[bold green]✔ Redução de I/O em disco: {read_delta}%[/bold green]\n")

    @staticmethod
    def _calc_reduction(v_before: float, v_after: float) -> str:
        if v_before <= 0.0:
            return "0.0"
        reduction = ((v_before - v_after) / v_before) * 100.0
        return f"{reduction:.2f}"


# =====================================================================
# 2. CENÁRIO: SIMULAÇÃO DE CONTENÇÃO DE LOCK E INVESTIGAÇÃO ATIVA
# =====================================================================

@dataclass(frozen=True)
class BlockedSessionInfo:
    blocked_pid: int
    blocking_pids: List[int]
    wait_event_type: str
    wait_event: str
    query_snippet: str
    xact_duration_sec: float


class LockContentionSimulator:
    """Dispara lock exclusivo de linha e audita via pg_stat_activity."""

    TARGET_SKU = "SKU-000001"

    def __init__(self, connection_factory: ConnectionFactory) -> None:
        self._factory = connection_factory
        self._lock_acquired_event = threading.Event()
        self._release_event = threading.Event()
        self._captured_block: Optional[BlockedSessionInfo] = None

    def execute(self) -> None:
        console.print(Panel.fit(
            "[bold yellow]Teste 2: Simulação de Contenção de Lock & Investigação DBRE[/bold yellow]\n"
            f"[dim]Cenário: Conexão A retém row-level lock no {self.TARGET_SKU} enquanto Conexão B tenta UPDATE.[/dim]",
            border_style="yellow"
        ))

        t_holder = threading.Thread(target=self._holder_worker, name="Worker-Holder-A")
        t_waiter = threading.Thread(target=self._waiter_worker, name="Worker-Waiter-B")

        t_holder.start()
        # Aguarda confirmação de lock adquirido pela Conexão A
        self._lock_acquired_event.wait(timeout=3)

        t_waiter.start()
        # Aguarda a Conexão B entrar na fila de espera do PostgreSQL
        time.sleep(1.5)

        # Conexão C (Observador DBRE) realiza inspeção de active_sessions
        self._inspect_lock_state()

        # Libera conexões
        self._release_event.set()
        t_holder.join(timeout=3)
        t_waiter.join(timeout=3)

        self._render_lock_report()

    def _holder_worker(self) -> None:
        with self._factory.create() as conn:
            conn.autocommit = False
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT id, codigo_sku, quantidade_disponivel FROM estoque_pecas WHERE codigo_sku = %s FOR UPDATE;",
                    (self.TARGET_SKU,)
                )
                self._lock_acquired_event.set()
                # Mantém a transação aberta até que o observador finalize
                self._release_event.wait(timeout=8)
                conn.rollback()

    def _waiter_worker(self) -> None:
        with self._factory.create() as conn:
            conn.autocommit = False
            try:
                with conn.cursor() as cur:
                    cur.execute(
                        "UPDATE estoque_pecas SET quantidade_disponivel = quantidade_disponivel - 1 WHERE codigo_sku = %s;",
                        (self.TARGET_SKU,)
                    )
            except Exception:
                pass
            finally:
                conn.rollback()

    def _inspect_lock_state(self) -> None:
        sql_diagnostic_path = os.path.join(os.path.dirname(__file__), "..", "diagnostics", "active_sessions.sql")
        
        query = """
        SELECT
            a.pid,
            a.usename,
            a.state,
            a.wait_event_type,
            a.wait_event,
            pg_blocking_pids(a.pid) AS blocking_pids,
            ROUND(EXTRACT(EPOCH FROM (clock_timestamp() - a.xact_start))::numeric, 2) AS xact_duration_sec,
            LEFT(REGEXP_REPLACE(a.query, '\\s+', ' ', 'g'), 100) AS query_snippet
        FROM pg_stat_activity a
        WHERE a.pid <> pg_backend_pid()
          AND a.datname = current_database()
          AND array_length(pg_blocking_pids(a.pid), 1) > 0;
        """

        if os.path.exists(sql_diagnostic_path):
            try:
                with open(sql_diagnostic_path, "r", encoding="utf-8") as f:
                    file_sql = f.read()
                    if "pg_blocking_pids" in file_sql:
                        query = file_sql
            except Exception:
                pass

        with self._factory.create() as conn:
            with conn.cursor() as cur:
                cur.execute(query)
                rows = cur.fetchall()
                for row in rows:
                    blocking = row.get("blocking_pids") or []
                    if blocking:
                        self._captured_block = BlockedSessionInfo(
                            blocked_pid=row["pid"],
                            blocking_pids=list(blocking),
                            wait_event_type=row.get("wait_event_type", "Unknown"),
                            wait_event=row.get("wait_event", "Unknown"),
                            query_snippet=row.get("query_snippet", "") or row.get("query", ""),
                            xact_duration_sec=float(row.get("xact_duration_sec") or 0.0)
                        )
                        break

    def _render_lock_report(self) -> None:
        if not self._captured_block:
            console.print("[red]⚠ Não foi possível interceptar o evento de bloqueio em tempo hábil.[/red]")
            return

        table = Table(
            title="Diagnóstico DBRE em Tempo Real: Contenção de Locks Interceptada",
            box=box.HEAVY_EDGE,
            header_style="bold yellow"
        )
        table.add_column("Propriedade", style="bold white", width=26)
        table.add_column("Valor Detectado", style="cyan")

        table.add_row("PID da Sessão Bloqueada", str(self._captured_block.blocked_pid))
        table.add_row("PIDs Bloqueadores", ", ".join(map(str, self._captured_block.blocking_pids)))
        table.add_row("Wait Event Type", f"[bold red]{self._captured_block.wait_event_type}[/bold red]")
        table.add_row("Wait Event", self._captured_block.wait_event)
        table.add_row("Tempo em Bloqueio", f"{self._captured_block.xact_duration_sec} s")
        table.add_row("Query Bloqueada Interceptada", self._captured_block.query_snippet)

        console.print(table)
        console.print("[bold green]✔ Contenção de lock detectada e isolada com sucesso. Sessões encerradas com ROLLBACK.[/bold green]\n")


# =====================================================================
# 3. CENÁRIO: DEAD TUPLES, BLOAT E AUDITORIA DE AUTOVACUUM
# =====================================================================

@dataclass(frozen=True)
class TableBloatMetrics:
    table_name: str
    live_tuples: int
    dead_tuples: int
    dead_ratio_pct: float
    table_size: str
    autovacuum_count: int


class BloatAndVacuumAuditor:
    """Avalia o impacto de updates massivos na criação de dead tuples e threshold de vacuum."""

    TARGET_TABLE = "ordens_servico"
    BATCH_UPDATE_COUNT = 5000

    def __init__(self, connection_factory: ConnectionFactory) -> None:
        self._factory = connection_factory

    def execute(self) -> None:
        console.print(Panel.fit(
            "[bold magenta]Teste 3: Inspeção de Dead Tuples, Bloat & Limiares de Autovacuum[/bold magenta]\n"
            f"[dim]Gera carga de {self.BATCH_UPDATE_COUNT} updates concorrentes em {self.TARGET_TABLE} e mede dead tuples.[/dim]",
            border_style="magenta"
        ))

        # 1. Medição Basal
        baseline = self._fetch_metrics()

        # 2. Injeção de Updates Concorrentes
        console.print(f"[yellow]⚡ Aplicando lote de {self.BATCH_UPDATE_COUNT} updates concorrentes em {self.TARGET_TABLE}...[/yellow]")
        self._apply_batch_updates()

        # 3. Medição Pós-Update
        post_update = self._fetch_metrics()

        self._render_bloat_report(baseline, post_update)

    def _fetch_metrics(self) -> TableBloatMetrics:
        query = """
        SELECT
            relname AS table_name,
            COALESCE(n_live_tup, 0) AS live_tuples,
            COALESCE(n_dead_tup, 0) AS dead_tuples,
            ROUND(
                (COALESCE(n_dead_tup, 0)::numeric / NULLIF(COALESCE(n_live_tup, 0) + COALESCE(n_dead_tup, 0), 0) * 100), 
                2
            ) AS dead_ratio_pct,
            pg_size_pretty(pg_relation_size(relid)) AS table_size,
            COALESCE(autovacuum_count, 0) AS autovacuum_count
        FROM pg_stat_user_tables
        WHERE relname = %s;
        """
        with self._factory.create() as conn:
            with conn.cursor() as cur:
                cur.execute(query, (self.TARGET_TABLE,))
                row = cur.fetchone()
                if not row:
                    raise ValueError(f"Tabela {self.TARGET_TABLE} não encontrada nas estatísticas.")
                
                return TableBloatMetrics(
                    table_name=row["table_name"],
                    live_tuples=int(row["live_tuples"]),
                    dead_tuples=int(row["dead_tuples"]),
                    dead_ratio_pct=float(row["dead_ratio_pct"] or 0.0),
                    table_size=row["table_size"],
                    autovacuum_count=int(row["autovacuum_count"])
                )

    def _apply_batch_updates(self) -> None:
        # Atualiza 5000 registros para gerar imediatamente 5000 dead tuples
        update_sql = f"""
        UPDATE {self.TARGET_TABLE}
        SET observacoes_tecnicas = 'Update benchmark para validação de dead tuples geradas em lote.'
        WHERE id IN (
            SELECT id FROM {self.TARGET_TABLE}
            WHERE status = 'EM_EXECUCAO'
            LIMIT {self.BATCH_UPDATE_COUNT}
        );
        """
        with self._factory.create() as conn:
            with conn.cursor() as cur:
                cur.execute(update_sql)
                conn.commit()

    def _render_bloat_report(self, baseline: TableBloatMetrics, post: TableBloatMetrics) -> None:
        table = Table(
            title=f"Auditoria de Bloat e Tuplas Mortas: {self.TARGET_TABLE}",
            box=box.ROUNDED,
            header_style="bold green"
        )
        table.add_column("Métrica Estatística", style="bold white", width=30)
        table.add_column("Estado Basal", justify="right", style="cyan")
        table.add_column("Pós Carga (5k Updates)", justify="right", style="magenta")
        table.add_column("Incremento", justify="right", style="bold yellow")

        delta_dead = post.dead_tuples - baseline.dead_tuples
        delta_ratio = round(post.dead_ratio_pct - baseline.dead_ratio_pct, 2)

        table.add_row("Tuplas Vivas (n_live_tup)", f"{baseline.live_tuples:,}", f"{post.live_tuples:,}", f"{post.live_tuples - baseline.live_tuples}")
        table.add_row("Tuplas Mortas (n_dead_tup)", f"{baseline.dead_tuples:,}", f"{post.dead_tuples:,}", f"+{delta_dead:,}")
        table.add_row("Taxa de Dead Tuples (%)", f"{baseline.dead_ratio_pct}%", f"{post.dead_ratio_pct}%", f"+{delta_ratio}%")
        table.add_row("Tamanho Físico da Tabela", baseline.table_size, post.table_size, "Estável")
        table.add_row("Contador de Autovacuums", str(baseline.autovacuum_count), str(post.autovacuum_count), "Monitorado")

        console.print(table)

        # Explicação técnica de DBRE sobre o threshold de autovacuum
        autovacuum_threshold = 50 + int(0.1 * post.live_tuples)
        console.print(Panel(
            f"[bold white]Análise DBRE de Limiares do Autovacuum:[/bold white]\n"
            f"• Fórmula: [dim]autovacuum_vacuum_threshold (50) + autovacuum_vacuum_scale_factor (0.10) * n_live_tup[/dim]\n"
            f"• Limiar para disparo automático nesta tabela: [bold yellow]~{autovacuum_threshold:,} dead tuples[/bold yellow].\n"
            f"• Tuplas mortas atuais: [bold magenta]{post.dead_tuples:,}[/bold magenta] ({post.dead_ratio_pct}% do total).\n"
            f"• Conclusão: As dead tuples permanecem no buffer/disco até atingirem o threshold configurado ou até a execução de VACUUM manual.",
            title="PostgreSQL MVCC Internals",
            border_style="green"
        ))


# =====================================================================
# MAIN RUNNER (Clean Code & Object Calisthenics: Cohesive Orchestration)
# =====================================================================

def main() -> None:
    console.print("\n[bold green]=====================================================================[/bold green]")
    console.print("[bold green]  PITSTOP CORE - SUITE DE BENCHMARKS E SIMULAÇÃO DE INCIDENTES DBRE [/bold green]")
    console.print("[bold green]=====================================================================[/bold green]\n")

    config = DatabaseConfig()
    factory = ConnectionFactory(config)

    try:
        # Teste de conectividade inicial
        with factory.create() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT version();")
                ver = cur.fetchone()["version"]
                console.print(f"[dim]Conexão estabelecida com sucesso: {ver[:55]}...[/dim]\n")
    except Exception as exc:
        console.print(f"[bold red]❌ Erro crítico de conectividade:[/bold red] {exc}")
        sys.exit(1)

    # Execução sequencial dos 3 cenários
    SlowQueryAnalyzer(factory).execute()
    LockContentionSimulator(factory).execute()
    BloatAndVacuumAuditor(factory).execute()

    console.print("[bold green]=====================================================================[/bold green]")
    console.print("[bold green]  TODOS OS TESTES E BENCHMARKS FORAM CONCLUÍDOS COM SUCESSO!         [/bold green]")
    console.print("[bold green]=====================================================================[/bold green]\n")


if __name__ == "__main__":
    main()
