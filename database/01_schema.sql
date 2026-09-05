-- =====================================================================
-- PITSTOP CORE - ESQUEMA RELACIONAL (01_schema.sql)
-- Arquitetura orientada a alta concorrência e integridade referencial
-- =====================================================================

-- Extensões para métricas de execução e utilitários
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Limpeza idempotente (caso executado manualmente em ambiente de testes)
DROP TABLE IF EXISTS itens_ordem CASCADE;
DROP TABLE IF EXISTS ordens_servico CASCADE;
DROP TABLE IF EXISTS estoque_pecas CASCADE;
DROP TABLE IF EXISTS veiculos CASCADE;
DROP TABLE IF EXISTS clientes CASCADE;

-- ---------------------------------------------------------------------
-- 1. TABELA: clientes
-- ---------------------------------------------------------------------
-- Decisão arquitetural:
-- - BIGINT GENERATED ALWAYS AS IDENTITY: Substitui o tipo SERIAL legado.
--   Previne inserções acidentais de IDs manuais e segue o padrão SQL ANSI.
-- - Status restrito via CHECK constraint para evitar valores anômalos.
CREATE TABLE clientes (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nome VARCHAR(150) NOT NULL,
    cpf_cnpj VARCHAR(18) NOT NULL,
    telefone VARCHAR(20) NOT NULL,
    email VARCHAR(150) NOT NULL,
    status VARCHAR(20) DEFAULT 'ativo' NOT NULL,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT ck_clientes_status CHECK (status IN ('ativo', 'inativo', 'bloqueado')),
    CONSTRAINT uq_clientes_cpf_cnpj UNIQUE (cpf_cnpj)
);

-- ---------------------------------------------------------------------
-- 2. TABELA: veiculos
-- ---------------------------------------------------------------------
-- Decisão arquitetural:
-- - ON DELETE RESTRICT: Previne exclusões acidentais de clientes com histórico de veículos.
-- - Placa com constraint UNIQUE (criação automática de índice B-Tree).
-- - Índice em cliente_id para otimizar joins comuns de histórico de frota por cliente.
CREATE TABLE veiculos (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cliente_id BIGINT NOT NULL,
    placa CHAR(7) NOT NULL,
    marca VARCHAR(50) NOT NULL,
    modelo VARCHAR(100) NOT NULL,
    ano_fabricacao INT NOT NULL,
    ano_modelo INT NOT NULL,
    quilometragem INT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT fk_veiculos_cliente FOREIGN KEY (cliente_id) REFERENCES clientes(id) ON DELETE RESTRICT,
    CONSTRAINT ck_veiculos_km CHECK (quilometragem >= 0),
    CONSTRAINT uq_veiculos_placa UNIQUE (placa)
);

CREATE INDEX idx_veiculos_cliente_id ON veiculos(cliente_id);

-- ---------------------------------------------------------------------
-- 3. TABELA: estoque_pecas
-- ---------------------------------------------------------------------
-- Decisão arquitetural:
-- - Base para o Lab 2 (Deadlock & Concurrency).
-- - Colunas de controle transacional: quantidade_disponivel e quantidade_reservada.
-- - CHECK constraints rigorosas para prevenir estoque negativo.
CREATE TABLE estoque_pecas (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_sku VARCHAR(50) NOT NULL,
    nome VARCHAR(150) NOT NULL,
    categoria VARCHAR(50) NOT NULL,
    quantidade_disponivel INT NOT NULL DEFAULT 0,
    quantidade_reservada INT NOT NULL DEFAULT 0,
    preco_unitario NUMERIC(10, 2) NOT NULL,
    updated_at TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    CONSTRAINT uq_estoque_sku UNIQUE (codigo_sku),
    CONSTRAINT ck_estoque_disponivel CHECK (quantidade_disponivel >= 0),
    CONSTRAINT ck_estoque_reservada CHECK (quantidade_reservada >= 0),
    CONSTRAINT ck_estoque_preco CHECK (preco_unitario > 0)
);

-- ---------------------------------------------------------------------
-- 4. TABELA: ordens_servico
-- ---------------------------------------------------------------------
-- Decisão arquitetural e Estratégia de Troubleshooting:
-- - Núcleo OLTP transacional com 500.000+ registros.
-- - DELIBERADAMENTE SEM ÍNDICES SECUNDÁRIOS em (status, data_abertura) ou (veiculo_id).
--   Esta decisão é o pilar do Lab 1 (Slow Query): qualquer busca operacional
--   como "Ordens em aberto nos últimos 30 dias" forçará um Sequential Scan completo
--   de 500k linhas com alto custo de buffer I/O em um pool de apenas 128MB.
CREATE TABLE ordens_servico (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    veiculo_id BIGINT NOT NULL,
    numero_os VARCHAR(30) NOT NULL,
    status VARCHAR(30) DEFAULT 'aberta' NOT NULL,
    data_abertura TIMESTAMPTZ DEFAULT clock_timestamp() NOT NULL,
    data_conclusao TIMESTAMPTZ NULL,
    valor_total NUMERIC(12, 2) DEFAULT 0.00 NOT NULL,
    descricao_problema TEXT NOT NULL,
    observacoes_tecnicas TEXT,
    CONSTRAINT fk_ordens_veiculo FOREIGN KEY (veiculo_id) REFERENCES veiculos(id) ON DELETE RESTRICT,
    CONSTRAINT uq_ordens_numero UNIQUE (numero_os),
    CONSTRAINT ck_ordens_status CHECK (upper(status) IN ('ABERTA', 'EM_ANALISE', 'AGUARDANDO_PECAS', 'EM_EXECUCAO', 'FINALIZADA', 'CANCELADA')),
    CONSTRAINT ck_ordens_valor CHECK (valor_total >= 0)
);

-- ---------------------------------------------------------------------
-- 5. TABELA: itens_ordem
-- ---------------------------------------------------------------------
-- Decisão arquitetural:
-- - Coluna calculada STORED: valor_total (quantidade * valor_unitario).
--   Garante integridade matemática a nível de armazenamento sem triggers adicionais.
-- - ON DELETE CASCADE em ordens_servico_id: se a OS for descartada, seus itens acompanham.
CREATE TABLE itens_ordem (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ordem_servico_id BIGINT NOT NULL,
    peca_id BIGINT NULL,
    tipo_item VARCHAR(20) NOT NULL,
    descricao VARCHAR(200) NOT NULL,
    quantidade INT NOT NULL,
    valor_unitario NUMERIC(10, 2) NOT NULL,
    valor_total NUMERIC(12, 2) GENERATED ALWAYS AS (quantidade * valor_unitario) STORED,
    CONSTRAINT fk_itens_ordem FOREIGN KEY (ordem_servico_id) REFERENCES ordens_servico(id) ON DELETE CASCADE,
    CONSTRAINT fk_itens_peca FOREIGN KEY (peca_id) REFERENCES estoque_pecas(id) ON DELETE RESTRICT,
    CONSTRAINT ck_itens_tipo CHECK (tipo_item IN ('peca', 'servico')),
    CONSTRAINT ck_itens_quantidade CHECK (quantidade > 0),
    CONSTRAINT ck_itens_valor_unitario CHECK (valor_unitario >= 0)
);

CREATE INDEX idx_itens_ordem_os_id ON itens_ordem(ordem_servico_id);
CREATE INDEX idx_itens_ordem_peca_id ON itens_ordem(peca_id);
