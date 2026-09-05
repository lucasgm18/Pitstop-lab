# PitStop Core - Laboratório de Confiabilidade e Internals PostgreSQL (DBRE)

Ambiente prático de engenharia de confiabilidade de banco de dados (Database Reliability Engineering - DBRE), reprodução de incidentes de alta performance, monitoramento e internals do PostgreSQL 16.

---

## 🏛 Arquitetura e Restrições de Hardware

O ambiente é orquestrado via Docker Compose com limites estritos de hardware aplicados via cgroups, projetado para evidenciar gargalos de CPU, contenção de locks e I/O de disco:

* **CPU**: `1.0 vCPU` (núcleo único isolado)
* **Memória RAM**: `512MB` (`mem_limit: 512m`, `mem_reservation: 256m`)
* **Volume Persistente**: `pitstop_pgdata`
* **Mapeamento de Porta Host**: `5433:5432` (isolado de instâncias locais legadas na 5432)

### Orçamento de Memória (Memory Budgeting)

Sob o teto rígido de 512MB, os parâmetros de engine do PostgreSQL foram calculados para prevenir a terminação abrupta pelo Linux OOM Killer:

| Parâmetro | Valor | Justificativa de Engenharia |
| :--- | :--- | :--- |
| `shared_buffers` | `128MB` | 25% da RAM total do container para buffer pool compartilhado. |
| `work_mem` | `4MB` | Baixo para evidenciar *spills* para disco (`external merge sort`) em ordenações não otimizadas. |
| `maintenance_work_mem` | `64MB` | Otimização para criação de índices e comandos `VACUUM` rápidos. |
| `effective_cache_size` | `384MB` | Informa ao planejador de consultas a soma aproximada de RAM + Page Cache Linux (~75%). |
| `max_connections` | `50` | Contém a proliferação de conexões privadas para evitar saturação de memória. |
| `log_min_duration_statement`| `200ms` | Registro obrigatório de queries lentas. |
| `log_lock_waits` | `on` | Alerta automático de transações aguardando locks por mais de 1s (`deadlock_timeout`). |
| `log_temp_files` | `0` | Loga a criação de **qualquer** arquivo temporário em disco gerado por falta de `work_mem`. |
| `track_io_timing` | `on` | Cronometragem de tempo de leitura/escrita de blocos em `pg_stat_database`. |

---

## 📊 Esquema Relacional e Geração de Carga Sintética

O domínio modela a operação transacional de uma rede de oficinas automotivas:

* `clientes`: 50.000 registros
* `estoque_pecas`: 2.000 registros (distribuídos em 10 categorias reais)
* `veiculos`: 200.000 registros (placas Mercosul garantidamente únicas)
* `ordens_servico`: 500.000 registros (75% finalizadas, 10% abertas, 5% canceladas, datas retroativas de 2 anos)
* `itens_ordem`: 1.000.000 registros (coluna computada `STORED` para `valor_total`)

### Seed em Alta Performance (Set-Based Generation)

Em vez de cursores e laços `LOOP` linha a linha, o script [database/02_seed.sql](database/02_seed.sql) adota pipeline vetorial via `generate_series`, populando **1.752.000 registros em ~45 segundos** com pico de memória de apenas 181 MB (35% do limite).

---

## 🔬 Suite Automatizada de Benchmarks e Incidentes

O projeto conta com um runner automatizado em Python 3.11+ ([tests/run_incident_benchmarks.py](tests/run_incident_benchmarks.py)) estruturado com princípios de **Clean Code** e **Object Calisthenics** (métodos curtos, retornos antecipados, sem `else` redundante, tipagem estrita com dataclasses e pooling seguro).

### 1. Teste 1: Query Lenta & Spill de Disco (I/O e Memória)
- Analisa busca de 50 ordens em execução com valor > 1500 em 500k linhas via `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)`.
- Evidencia `Seq Scan` lendo mais de 55.000 blocos do disco.
- Cria dinamicamente o índice parcial:
  ```sql
  CREATE INDEX idx_bench_os_execucao 
  ON ordens_servico (valor_total, data_abertura DESC, veiculo_id) 
  WHERE status = 'EM_EXECUCAO';
  ```
- **Resultado Obtido**:
  - Redução de tempo de execução: **86.64%** (73.96ms ➔ 9.88ms)
  - Redução de I/O em disco: **98.46%** (55.264 blocos ➔ 852 blocos)
  - Redução de custo do otimizador: **99.95%** (17.941 ➔ 8.32)
- Remove o índice ao final garantindo idempotência total do laboratório.

### 2. Teste 2: Simulação de Contenção de Lock & Investigação DBRE
- A Conexão A adquire lock exclusivo de linha em `SKU-000001` via `SELECT ... FOR UPDATE`.
- A Conexão B concorre e tenta realizar `UPDATE`, ficando imediatamente suspensa na fila de locks do engine.
- A Conexão C (Observador DBRE) executa a query [diagnostics/active_sessions.sql](diagnostics/active_sessions.sql) e intercepta em tempo real:
  - PID bloqueado
  - PIDs bloqueadores (`pg_blocking_pids`)
  - Wait event type (`Lock` / `transactionid`)
  - Trecho da query SQL interceptada
- Ambas as transações são encerradas com `ROLLBACK`.

### 3. Teste 3: Inspeção de Dead Tuples e Internals do MVCC
- Medição basal de `n_live_tup` e `n_dead_tup` via `pg_stat_user_tables`.
- Injeção de lote concorrente de **5.000 updates** em `ordens_servico`.
- Inspeção pós-carga evidenciando a geração de exatamente **+5.000 dead tuples** pelo mecanismo MVCC.
- Demonstração do cálculo de disparo automático do autovacuum daemon:
  $$\text{Threshold} = \text{autovacuum\_vacuum\_threshold}\,(50) + \text{autovacuum\_vacuum\_scale\_factor}\,(0.10) \times n\_live\_tup$$

---

## 🛠 Coleção de Scripts de Diagnóstico SQL

Localizados no diretório [diagnostics/](diagnostics/):

* [diagnostics/active_sessions.sql](diagnostics/active_sessions.sql): Auditoria detalhada de conexões ativas, transações longas e mapeamento de sessões bloqueadas.
* [diagnostics/table_bloat_check.sql](diagnostics/table_bloat_check.sql): Estimativa de tuplas mortas, razão percentual de bloat e contadores de autovacuum por tabela.
* [diagnostics/unused_indexes.sql](diagnostics/unused_indexes.sql): Rastreamento de índices sem leituras (`idx_scan = 0`) para prevenção de sobrecarga de escrita.

---

## 🚀 Como Executar

### 1. Pré-requisitos
* Docker e Docker Compose instalados.

### 2. Configuração de Credenciais
Copie o modelo de variáveis de ambiente:
```bash
cp docker/.env.example docker/.env
```
Edite `docker/.env` com sua senha desejada (o arquivo `.env` é ignorado pelo Git e **nunca** é enviado ao repositório).

### 3. Subir o Ambiente
```bash
docker compose -f docker/docker-compose.yml up -d
```
O PostgreSQL inicializará e executará automaticamente o esquema e a geração de dados sintéticos via `docker-entrypoint-initdb.d`.

### 4. Executar a Suite de Incidentes
```bash
./run_benchmarks.sh
```

---

## 🔒 Segurança

Este repositório é público. Por diretriz de segurança:
* Arquivos `.env` e credenciais sensíveis estão estritamente incluídos no `.gitignore`.
* Nenhum dado de conexão de produção ou segredo está embutido nos fontes.
