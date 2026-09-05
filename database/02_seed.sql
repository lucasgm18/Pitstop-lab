-- =====================================================================
-- PITSTOP CORE - SEED MASSIVO DE DADOS SINTÉTICOS (02_seed.sql)
-- Geração de alta performance baseada em conjuntos (Set-Based Generation)
-- Volumetria: 50k clientes, 2k peças, 200k veículos, 500k OS, 1M itens
-- =====================================================================

\timing on
SET client_min_messages = notice;

DO $$
BEGIN
    RAISE NOTICE '>>> [PITSTOP SEED] Iniciando geração massiva de dados sintéticos...';
END $$;

-- ---------------------------------------------------------------------
-- 1. POPULAR: clientes (50.000 registros)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE '>>> [1/5] Inserindo 50.000 clientes...';
END $$;

INSERT INTO clientes (nome, cpf_cnpj, telefone, email, status, created_at)
SELECT
    (ARRAY[
        'Carlos', 'Ana', 'Bruno', 'Mariana', 'Roberto', 'Juliana', 'Fernando',
        'Camila', 'Marcos', 'Patricia', 'Lucas', 'Beatriz', 'Rodrigo', 'Aline',
        'Eduardo', 'Fernanda', 'Gabriel', 'Larissa', 'Thiago', 'Vanessa'
    ])[1 + (i % 20)] || ' ' ||
    (ARRAY[
        'Silva', 'Santos', 'Oliveira', 'Souza', 'Pereira', 'Lima', 'Carvalho',
        'Ferreira', 'Ribeiro', 'Almeida', 'Costa', 'Gomes', 'Martins', 'Araujo',
        'Melo', 'Barbosa', 'Ribeiro', 'Cardoso', 'Teixeira', 'Cavalcanti'
    ])[1 + ((i / 20) % 20)] AS nome,
    lpad(i::text, 11, '0') AS cpf_cnpj,
    '119' || lpad((10000000 + (i % 89999999))::text, 8, '0') AS telefone,
    'cliente_' || i || '@pitstopmail.com.br' AS email,
    CASE 
        WHEN (i % 25) = 0 THEN 'bloqueado'
        WHEN (i % 15) = 0 THEN 'inativo'
        ELSE 'ativo'
    END AS status,
    NOW() - ((50000 - i) * INTERVAL '30 minutes') AS created_at
FROM generate_series(1, 50000) AS s(i);

-- ---------------------------------------------------------------------
-- 2. POPULAR: estoque_pecas (2.000 registros)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE '>>> [2/5] Inserindo 2.000 peças de estoque...';
END $$;

INSERT INTO estoque_pecas (codigo_sku, nome, categoria, quantidade_disponivel, quantidade_reservada, preco_unitario, updated_at)
SELECT
    'SKU-' || lpad(i::text, 6, '0') AS codigo_sku,
    'Peça ' || (ARRAY['Pastilha de Freio', 'Disco Ventilado', 'Amortecedor Dianteiro', 'Filtro de Óleo', 'Filtro de Combustível', 'Vela de Ignição', 'Correia Dentada', 'Bomba de Água', 'Óleo Sintético 5W30', 'Terminal de Direção'])[1 + (i % 10)] || ' Modelo ' || (i % 50) AS nome,
    (ARRAY['Freios', 'Suspensão', 'Motor', 'Filtros', 'Fluidos', 'Ignição', 'Arrefecimento', 'Direção', 'Transmissão', 'Elétrica'])[1 + (i % 10)] AS categoria,
    50 + (i % 300) AS quantidade_disponivel,
    0 AS quantidade_reservada,
    ROUND((19.90 + (i % 850) + (i % 99) * 0.15)::numeric, 2) AS preco_unitario,
    NOW() - ((2000 - i) * INTERVAL '2 hours') AS updated_at
FROM generate_series(1, 2000) AS s(i);

-- ---------------------------------------------------------------------
-- 3. POPULAR: veiculos (200.000 registros)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE '>>> [3/5] Inserindo 200.000 veículos...';
END $$;

INSERT INTO veiculos (cliente_id, placa, marca, modelo, ano_fabricacao, ano_modelo, quilometragem, created_at)
SELECT
    1 + ((i - 1) % 50000) AS cliente_id,
    'V' || lpad(i::text, 6, '0') AS placa,
    (ARRAY['Fiat', 'Volkswagen', 'Chevrolet', 'Hyundai', 'Toyota', 'Ford', 'Honda', 'Renault', 'Jeep', 'Nissan'])[1 + (i % 10)] AS marca,
    (ARRAY['Uno 1.0 Fire', 'Gol 1.6 MSI', 'Onix Turbo Premier', 'HB20 Diamond', 'Corolla XEi 2.0', 'Ka SE 1.0', 'Civic EXL 2.0', 'Kwid Zen 1.0', 'Renegade Longitude 1.3T', 'Kicks SV 1.6'])[1 + (i % 10)] AS modelo,
    2010 + (i % 14) AS ano_fabricacao,
    2010 + (i % 14) + (i % 2) AS ano_modelo,
    ((i * 47) % 280000) AS quilometragem,
    NOW() - ((200000 - i) * INTERVAL '5 minutes') AS created_at
FROM generate_series(1, 200000) AS s(i);

-- ---------------------------------------------------------------------
-- 4. POPULAR: ordens_servico (500.000 registros)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE '>>> [4/5] Inserindo 500.000 ordens de serviço...';
END $$;

INSERT INTO ordens_servico (veiculo_id, numero_os, status, data_abertura, data_conclusao, valor_total, descricao_problema, observacoes_tecnicas)
SELECT
    1 + ((i - 1) % 200000) AS veiculo_id,
    'OS-' || lpad(i::text, 8, '0') AS numero_os,
    status_calculado AS status,
    data_abertura_calc AS data_abertura,
    CASE
        WHEN status_calculado = 'finalizada' THEN data_abertura_calc + ((2 + (i % 72)) * INTERVAL '1 hour')
        ELSE NULL
    END AS data_conclusao,
    ROUND((120.00 + (i % 3800) + (i % 97) * 0.45)::numeric, 2) AS valor_total,
    (ARRAY[
        'Barulho metálico na suspensão dianteira ao trafegar em paralelepípedos',
        'Luz indicadora de injeção acesa intermitente em velocidade constante',
        'Pedal de freio com curso excessivamente longo e vibração na frenagem',
        'Temperatura do motor subindo rapidamente com ar condicionado ativado',
        'Dificuldade severa de partida matinal com oscilação na marcha lenta',
        'Mancha de fluido lubrificante identificada no chão da garagem',
        'Troca de correia dentada, tensor e revisão geral do sistema de sincronismo',
        'Ar condicionado perdeu a eficiência térmica após vazamento de gás',
        'Trepidação perceptível no conjunto de embreagem ao engatar primeira marcha',
        'Revisão periódica programada de troca de filtros, fluidos e velas'
    ])[1 + (i % 10)] AS descricao_problema,
    CASE 
        WHEN status_calculado = 'finalizada' THEN 'Serviço executado e testado em pista com aprovação do cliente.'
        WHEN status_calculado = 'aguardando_pecas' THEN 'Peças pendentes de faturamento pelo fornecedor central.'
        WHEN status_calculado = 'em_execucao' THEN 'Veículo no elevador 3 em processo de desmontagem.'
        ELSE NULL
    END AS observacoes_tecnicas
FROM (
    SELECT
        i,
        CASE
            WHEN (i % 100) < 75 THEN 'finalizada'        -- 75% finalizadas (histórico de anos)
            WHEN (i % 100) < 80 THEN 'cancelada'         -- 5% canceladas
            WHEN (i % 100) < 90 THEN 'aberta'            -- 10% abertas (alvo para Lab 1)
            WHEN (i % 100) < 94 THEN 'em_analise'        -- 4% em análise
            WHEN (i % 100) < 97 THEN 'aguardando_pecas'  -- 3% aguardando peças
            ELSE 'em_execucao'                           -- 3% em execução
        END AS status_calculado,
        NOW() - ((500000 - i) * INTERVAL '120 seconds') AS data_abertura_calc
    FROM generate_series(1, 500000) AS s(i)
) AS sub;

-- ---------------------------------------------------------------------
-- 5. POPULAR: itens_ordem (1.000.000 registros)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE '>>> [5/5] Inserindo 1.000.000 itens de ordens de serviço...';
END $$;

INSERT INTO itens_ordem (ordem_servico_id, peca_id, tipo_item, descricao, quantidade, valor_unitario)
SELECT
    1 + ((i - 1) % 500000) AS ordem_servico_id,
    CASE WHEN (i % 2) = 0 THEN 1 + ((i - 1) % 2000) ELSE NULL END AS peca_id,
    CASE WHEN (i % 2) = 0 THEN 'peca' ELSE 'servico' END AS tipo_item,
    CASE 
        WHEN (i % 2) = 0 THEN 'Item de reposição mecânica cód ' || (1 + ((i - 1) % 2000))
        ELSE 'Serviço técnico especializado de diagnóstico/montagem'
    END AS descricao,
    1 + (i % 4) AS quantidade,
    ROUND((25.00 + (i % 350) + (i % 50) * 0.65)::numeric, 2) AS valor_unitario
FROM generate_series(1, 1000000) AS s(i);

-- ---------------------------------------------------------------------
-- 6. ATUALIZAÇÃO ESTATÍSTICA DO CATÁLOGO POSTGRESQL (CRUCIAL PARA O PLANNER)
-- ---------------------------------------------------------------------
DO $$
BEGIN
    RAISE NOTICE '>>> [ANALYZE] Coletando estatísticas do otimizador (pg_statistic)...';
END $$;

VACUUM ANALYZE clientes;
VACUUM ANALYZE veiculos;
VACUUM ANALYZE estoque_pecas;
VACUUM ANALYZE ordens_servico;
VACUUM ANALYZE itens_ordem;

DO $$
BEGIN
    RAISE NOTICE '>>> [PITSTOP SEED] Seed massivo concluído com sucesso total!';
END $$;
