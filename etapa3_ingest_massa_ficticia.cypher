// ============================================================
// RadarPNCP — Ingest de massa de dados FICTÍCIA (>= 1000 itens)
// PECE/USP eEDB-016 — Repositórios de Dados e NoSQL
// Tecnologia: Neo4j (grafos)
//
// Objetivo: complementar o arquivo etapa3_poc_radarpncp.cypher
// (que contém 10 contratos de demonstração) com uma massa maior
// de dados fictícios, para testar volume, performance e os
// padrões de risco (fracionamento, recontratação, mesmo
// endereço, fornecedor multiórgão) em escala.
//
// PRÉ-REQUISITO: rode primeiro o etapa3_poc_radarpncp.cypher
// (ele cria as constraints e os nós de Modalidade m1/m2, além
// dos 3 órgãos e 5 fornecedores originais). Este arquivo
// pressupõe que Modalidade{id_modalidade:1} (Pregão Eletrônico)
// e Modalidade{id_modalidade:2} (Dispensa de Licitação) já
// existem — se preferir rodar isolado, descomente o bloco 0.1.
//
// Namespacing: todos os itens fictícios usam prefixo 'FICT-'
// nas chaves de negócio (cnpj, ni_fornecedor, id_contrato_pncp),
// para nunca colidir com os dados de demonstração da Etapa 1/2.
//
// Volume gerado:
//   - 100 OrgaoPublico fictícios
//   - 400 Fornecedor fictícios (com grupos de endereço repetido
//     para alimentar MESMO_ENDERECO / Q4 / Q5)
//   - 1000 Contrato fictícios "normais" (distribuição de datas,
//     valores e objetos variados, multiórgão embutido)
//   - 100 Contrato fictícios adicionais em 50 pares deliberados
//     de FRACIONAMENTO (mesmo órgão + mesmo fornecedor, objeto
//     quase idêntico, <=30 dias de intervalo, ambos abaixo do
//     limiar de dispensa) — para validar Q6/Q7 em escala
//   - Total de nós fictícios novos: 100+400+1000+100 = 1600
//     (bem acima dos 1000 itens solicitados)
//   - Relacionamentos: CONTRATOU, FORNECEU, DE_MODALIDADE para
//     cada contrato (~3300 arestas) + MESMO_ENDERECO entre
//     fornecedores fictícios do mesmo grupo de endereço
//
// Como executar:
//   cypher-shell -u neo4j -p <senha> -f etapa3_ingest_massa_ficticia.cypher
// ============================================================

// ------------------------------------------------------------
// 0.1 (OPCIONAL) — Descomente se for rodar este arquivo isolado,
// sem ter executado antes o etapa3_poc_radarpncp.cypher
// ------------------------------------------------------------
// CREATE CONSTRAINT orgao_cnpj IF NOT EXISTS FOR (o:OrgaoPublico) REQUIRE o.cnpj IS UNIQUE;
// CREATE CONSTRAINT fornecedor_ni IF NOT EXISTS FOR (f:Fornecedor) REQUIRE f.ni_fornecedor IS UNIQUE;
// CREATE CONSTRAINT contrato_id IF NOT EXISTS FOR (c:Contrato) REQUIRE c.id_contrato_pncp IS UNIQUE;
// CREATE CONSTRAINT modalidade_id IF NOT EXISTS FOR (m:Modalidade) REQUIRE m.id_modalidade IS UNIQUE;
// MERGE (:Modalidade {id_modalidade:1, nome:'Pregão Eletrônico'});
// MERGE (:Modalidade {id_modalidade:2, nome:'Dispensa de Licitação'});

// ------------------------------------------------------------
// 1. Índices auxiliares (melhoram performance das buscas de
// data e valor usadas pelas queries Q6/Q7 em massa)
// ------------------------------------------------------------
CREATE INDEX contrato_data IF NOT EXISTS FOR (c:Contrato) ON (c.data_assinatura);
CREATE INDEX contrato_valor IF NOT EXISTS FOR (c:Contrato) ON (c.valor_global);

// ------------------------------------------------------------
// 2. OrgaoPublico fictícios (100)
// cnpj sintético no formato 'FICT-ORG-NNNN' (garante unicidade
// via constraint já existente; não é um CNPJ válido, é só uma
// chave de negócio fictícia para fins de carga de teste)
// ------------------------------------------------------------
UNWIND range(1, 100) AS i
WITH i,
     substring('0000' + toString(i), size('0000' + toString(i)) - 4, 4) AS pad4,
     ['Instituto Federal','Secretaria Estadual','Prefeitura Municipal','Universidade Federal',
      'Fundação Pública','Autarquia Municipal','Câmara Municipal','Departamento Estadual'] AS tipos,
     ['Educação','Saúde','Obras','Cultura','Meio Ambiente','Segurança Pública','Transporte',
      'Assistência Social','Ciência e Tecnologia','Agricultura'] AS areas
WITH i, pad4, tipos[i % size(tipos)] AS tipo, areas[i % size(areas)] AS area
CREATE (:OrgaoPublico {
  cnpj: 'FICT-ORG-' + pad4,
  nome: tipo + ' Fictício de ' + area + ' nº ' + toString(i),
  codigo_unidade: 'UORG' + pad4,
  nome_unidade: 'Unidade Administrativa ' + toString(i)
});

// ------------------------------------------------------------
// 3. Fornecedor fictícios (400)
// Agrupados em 80 "grupos de endereço" (i % 80) — cada grupo
// tem ~5 fornecedores no mesmo logradouro/número, alimentando
// a rede MESMO_ENDERECO usada por Q4/Q5 em escala.
// A cada 15º fornecedor é PF (pessoa física), o resto é PJ.
// ------------------------------------------------------------
UNWIND range(1, 400) AS i
WITH i,
     substring('0000' + toString(i), size('0000' + toString(i)) - 4, 4) AS pad4,
     i % 80 AS grupo,
     ['Rua das Flores','Av. Central','Rua do Comércio','Av. Brasil','Rua da Paz',
      'Rua XV de Novembro','Av. das Palmeiras','Rua São João','Rua Sete de Setembro',
      'Av. Getúlio Vargas'] AS ruas
WITH i, pad4, grupo, ruas[grupo % size(ruas)] AS rua, (100 + grupo * 3) AS numero
CREATE (:Fornecedor {
  ni_fornecedor: CASE WHEN i % 15 = 0 THEN 'FICT-CPF-' + pad4 ELSE 'FICT-CNPJ-' + pad4 END,
  nome: CASE WHEN i % 15 = 0
             THEN 'Prestador Fictício ' + toString(i) + ' ME'
             ELSE 'Empresa Fictícia ' + toString(i) + ' Ltda' END,
  tipo_pessoa: CASE WHEN i % 15 = 0 THEN 'PF' ELSE 'PJ' END,
  endereco: rua + ', ' + toString(numero)
});

// ------------------------------------------------------------
// 4. MESMO_ENDERECO entre fornecedores fictícios do mesmo grupo
// (mesmo endereço exato) — dedupe por ordenação de chave para
// não criar arestas espelhadas (A,B) e (B,A).
// ------------------------------------------------------------
MATCH (a:Fornecedor), (b:Fornecedor)
WHERE a.endereco = b.endereco
  AND a.ni_fornecedor < b.ni_fornecedor
  AND a.ni_fornecedor STARTS WITH 'FICT'
  AND b.ni_fornecedor STARTS WITH 'FICT'
CREATE (a)-[:MESMO_ENDERECO]->(b);

// ------------------------------------------------------------
// 5. Contrato fictícios "normais" (1000)
// Distribuição:
//   - orgao_idx = ((i*37) % 100) + 1  → espalha contratos entre
//     os 100 órgãos fictícios
//   - forn_idx  = ((i*7)  % 400) + 1  → espalha entre os 400
//     fornecedores; como o período é diferente do dos órgãos,
//     naturalmente surgem fornecedores multiórgão (Q3)
//   - valor entre R$ 1.000 e R$ 25.500
//   - modalidade: Dispensa (2) se valor < 10.000, senão Pregão (1)
//   - datas espalhadas entre 2024-01-01 e ~2026-06 (dias_offset
//     até 899), compatível com a data corrente do projeto
// ------------------------------------------------------------
UNWIND range(1, 1000) AS i
WITH i,
     substring('0000' + toString(i), size('0000' + toString(i)) - 4, 4) AS pad4,
     ((i * 37) % 100) + 1 AS orgao_idx,
     ((i * 7) % 400) + 1 AS forn_idx,
     (i % 50) AS valor_bucket,
     (i % 15) AS objeto_idx,
     (i * 3) % 900 AS dias_offset
WITH i, pad4, orgao_idx, forn_idx, valor_bucket, objeto_idx, dias_offset,
     substring('0000' + toString(orgao_idx), size('0000' + toString(orgao_idx)) - 4, 4) AS orgao_pad,
     substring('0000' + toString(forn_idx), size('0000' + toString(forn_idx)) - 4, 4) AS forn_pad,
     CASE WHEN forn_idx % 15 = 0 THEN 'FICT-CPF-' ELSE 'FICT-CNPJ-' END AS forn_prefix,
     toFloat(1000 + valor_bucket * 500) AS valor,
     date('2024-01-01') + duration({days: dias_offset}) AS data_assinatura,
     ['Aquisição de material de escritório','Aquisição de material de expediente',
      'Serviços de manutenção predial','Fornecimento de equipamentos de informática',
      'Serviço de consultoria técnica','Contratação de serviço de limpeza',
      'Aquisição de suprimentos de informática','Obra de reforma de unidade',
      'Serviços de pintura e reparos','Aquisição de veículos oficiais',
      'Locação de equipamentos','Serviços de tecnologia da informação',
      'Fornecimento de gêneros alimentícios','Aquisição de mobiliário',
      'Serviços gráficos e de impressão'] AS objetos
WITH i, pad4, orgao_pad, forn_prefix, forn_pad, valor, data_assinatura, objetos[objeto_idx] AS objeto
MATCH (o:OrgaoPublico {cnpj: 'FICT-ORG-' + orgao_pad})
MATCH (f:Fornecedor {ni_fornecedor: forn_prefix + forn_pad})
MATCH (m:Modalidade {id_modalidade: CASE WHEN valor < 10000 THEN 2 ELSE 1 END})
CREATE (c:Contrato {
  id_contrato_pncp: 'PNCP-2026-F' + pad4,
  numero_contrato: 'F' + pad4 + '/2026',
  processo: 'PROC-F' + pad4 + '/2026',
  objeto_contrato: objeto,
  valor_inicial: valor,
  valor_global: valor,
  valor_parcelas: valor,
  data_assinatura: data_assinatura,
  data_vigencia_inicio: data_assinatura + duration({days: 1}),
  data_vigencia_fim: data_assinatura + duration({months: 6}),
  data_publicacao: data_assinatura + duration({days: 3})
})
CREATE (o)-[:CONTRATOU]->(c)
CREATE (f)-[:FORNECEU]->(c)
CREATE (c)-[:DE_MODALIDADE]->(m);

// ------------------------------------------------------------
// 6. Pares deliberados de FRACIONAMENTO (50 pares = 100 contratos)
// Mesmo órgão + mesmo fornecedor, objeto quase idêntico, ambos
// contratos abaixo do limiar de dispensa (R$ 10.000) e assinados
// com 3 a 12 dias de intervalo — sinal clássico de fracionamento
// para escapar da licitação. Alimenta Q6 (recorrência) e Q7
// (recorrência + valor sob o limiar) em escala.
// ------------------------------------------------------------
UNWIND range(1, 50) AS i
WITH i,
     substring('0000' + toString(i), size('0000' + toString(i)) - 4, 4) AS pad4,
     ((i * 13) % 100) + 1 AS orgao_idx,
     ((i * 11) % 400) + 1 AS forn_idx,
     (i % 10) AS dias_gap,
     (i * 5) AS dias_offset_base,
     (6000 + (i % 30) * 100) AS valor1,
     (6000 + ((i + 7) % 30) * 100) AS valor2
WITH i, pad4, dias_gap, valor1, valor2,
     substring('0000' + toString(orgao_idx), size('0000' + toString(orgao_idx)) - 4, 4) AS orgao_pad,
     substring('0000' + toString(forn_idx), size('0000' + toString(forn_idx)) - 4, 4) AS forn_pad,
     CASE WHEN forn_idx % 15 = 0 THEN 'FICT-CPF-' ELSE 'FICT-CNPJ-' END AS forn_prefix,
     date('2025-01-01') + duration({days: dias_offset_base}) AS data1
WITH i, pad4, orgao_pad, forn_prefix, forn_pad, valor1, valor2, data1,
     data1 + duration({days: 3 + dias_gap}) AS data2
MATCH (o:OrgaoPublico {cnpj: 'FICT-ORG-' + orgao_pad})
MATCH (f:Fornecedor {ni_fornecedor: forn_prefix + forn_pad})
MATCH (m2:Modalidade {id_modalidade: 2})
CREATE (c1:Contrato {
  id_contrato_pncp: 'PNCP-2026-FRAC' + pad4 + 'A',
  numero_contrato: 'FRAC' + pad4 + 'A/2026',
  processo: 'PROC-FRAC' + pad4 + 'A/2026',
  objeto_contrato: 'Aquisição fracionada de material (lote ' + toString(i) + ')',
  valor_inicial: toFloat(valor1), valor_global: toFloat(valor1), valor_parcelas: toFloat(valor1),
  data_assinatura: data1,
  data_vigencia_inicio: data1 + duration({days: 1}),
  data_vigencia_fim: data1 + duration({months: 6}),
  data_publicacao: data1 + duration({days: 2})
})
CREATE (c2:Contrato {
  id_contrato_pncp: 'PNCP-2026-FRAC' + pad4 + 'B',
  numero_contrato: 'FRAC' + pad4 + 'B/2026',
  processo: 'PROC-FRAC' + pad4 + 'B/2026',
  objeto_contrato: 'Aquisição fracionada de material (lote ' + toString(i) + ')',
  valor_inicial: toFloat(valor2), valor_global: toFloat(valor2), valor_parcelas: toFloat(valor2),
  data_assinatura: data2,
  data_vigencia_inicio: data2 + duration({days: 1}),
  data_vigencia_fim: data2 + duration({months: 6}),
  data_publicacao: data2 + duration({days: 2})
})
CREATE (o)-[:CONTRATOU]->(c1)
CREATE (o)-[:CONTRATOU]->(c2)
CREATE (f)-[:FORNECEU]->(c1)
CREATE (f)-[:FORNECEU]->(c2)
CREATE (c1)-[:DE_MODALIDADE]->(m2)
CREATE (c2)-[:DE_MODALIDADE]->(m2);

// ============================================================
// 7. Conferência pós-carga (rode manualmente para validar)
// ============================================================

// 7.1 — Contagem geral de nós fictícios criados
MATCH (o:OrgaoPublico) WHERE o.cnpj STARTS WITH 'FICT-ORG-'
WITH count(o) AS qtd_orgaos
MATCH (f:Fornecedor) WHERE f.ni_fornecedor STARTS WITH 'FICT-'
WITH qtd_orgaos, count(f) AS qtd_fornecedores
MATCH (c:Contrato) WHERE c.id_contrato_pncp STARTS WITH 'PNCP-2026-F'
RETURN qtd_orgaos, qtd_fornecedores, count(c) AS qtd_contratos,
       qtd_orgaos + qtd_fornecedores + count(c) AS total_itens_ficticios;

// 7.2 — Testar Q3 (multiórgão) já em escala com a massa nova
// MATCH (f:Fornecedor)-[:FORNECEU]->(:Contrato)<-[:CONTRATOU]-(o:OrgaoPublico)
// WITH f, count(DISTINCT o) AS qtd_orgaos
// WHERE qtd_orgaos > 1
// RETURN f.nome AS fornecedor, qtd_orgaos
// ORDER BY qtd_orgaos DESC
// LIMIT 20;

// 7.3 — Testar Q7 (fracionamento) já em escala com a massa nova
// MATCH (o:OrgaoPublico)-[:CONTRATOU]->(c1:Contrato)<-[:FORNECEU]-(f:Fornecedor),
//       (o)-[:CONTRATOU]->(c2:Contrato)<-[:FORNECEU]-(f)
// WHERE c1.id_contrato_pncp < c2.id_contrato_pncp
//   AND coalesce(c1.valor_global, 0) < 10000
//   AND coalesce(c2.valor_global, 0) < 10000
// WITH o, f, c1, c2,
//      abs(duration.inDays(date(c1.data_assinatura), date(c2.data_assinatura)).days) AS dias
// WHERE dias <= 30
// RETURN f.nome AS fornecedor, o.nome AS orgao,
//        c1.numero_contrato AS contrato_1, c2.numero_contrato AS contrato_2,
//        dias AS dias_entre_contratos
// ORDER BY dias ASC
// LIMIT 20;
