// ============================================================
// RadarPNCP — Etapa 3: Implementação e Validação (PoC)
// PECE/USP eEDB-016 — Repositórios de Dados e NoSQL
// Tecnologia: Neo4j (grafos)
// ============================================================
// Como executar:
//   cypher-shell -u neo4j -p <senha> -f etapa3_poc_radarpncp.cypher
// ou colar cada bloco no Neo4j Browser.
// ============================================================

// ------------------------------------------------------------
// 0. Limpeza (opcional, útil para reexecutar a PoC do zero)
// ------------------------------------------------------------
MATCH (n) DETACH DELETE n;

// ------------------------------------------------------------
// 1. Constraints de unicidade (chaves de negócio)
// ------------------------------------------------------------
CREATE CONSTRAINT orgao_cnpj IF NOT EXISTS FOR (o:OrgaoPublico) REQUIRE o.cnpj IS UNIQUE;
CREATE CONSTRAINT fornecedor_ni IF NOT EXISTS FOR (f:Fornecedor) REQUIRE f.ni_fornecedor IS UNIQUE;
CREATE CONSTRAINT contrato_id IF NOT EXISTS FOR (c:Contrato) REQUIRE c.id_contrato_pncp IS UNIQUE;
CREATE CONSTRAINT modalidade_id IF NOT EXISTS FOR (m:Modalidade) REQUIRE m.id_modalidade IS UNIQUE;

// ------------------------------------------------------------
// 2. Nós — OrgaoPublico (3)
// ------------------------------------------------------------
CREATE (o1:OrgaoPublico {cnpj:'00.000.000/0001-91', nome:'Instituto Federal de Educação Alfa', codigo_unidade:'IFA01', nome_unidade:'Reitoria'});
CREATE (o2:OrgaoPublico {cnpj:'11.111.111/0001-22', nome:'Secretaria Estadual de Saúde Beta', codigo_unidade:'SESB01', nome_unidade:'Unidade Central'});
CREATE (o3:OrgaoPublico {cnpj:'22.222.222/0001-33', nome:'Prefeitura Municipal de Gama', codigo_unidade:'PMG01', nome_unidade:'Secretaria de Obras'});

// ------------------------------------------------------------
// 3. Nós — Modalidade (2)
// ------------------------------------------------------------
CREATE (m1:Modalidade {id_modalidade:1, nome:'Pregão Eletrônico'});
CREATE (m2:Modalidade {id_modalidade:2, nome:'Dispensa de Licitação'});

// ------------------------------------------------------------
// 4. Nós — Fornecedor (5)
// endereco é um atributo simulado (a API PNCP não traz esse
// campo) — necessário só para viabilizar Q4/Q5.
// ------------------------------------------------------------
CREATE (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00', nome:'Alfa Serviços Ltda', tipo_pessoa:'PJ', endereco:'Rua das Acácias, 100'});
CREATE (f2:Fornecedor {ni_fornecedor:'23.456.789/0001-11', nome:'Beta Soluções Ltda', tipo_pessoa:'PJ', endereco:'Rua das Acácias, 100'});
CREATE (f3:Fornecedor {ni_fornecedor:'34.567.890/0001-22', nome:'Gama Construções S.A.', tipo_pessoa:'PJ', endereco:'Av. Industrial, 500'});
CREATE (f4:Fornecedor {ni_fornecedor:'45.678.901/0001-33', nome:'Delta Materiais Ltda', tipo_pessoa:'PJ', endereco:'Rua das Acácias, 102'});
CREATE (f5:Fornecedor {ni_fornecedor:'78.912.345-00', nome:'João da Silva ME', tipo_pessoa:'PF', endereco:'Rua das Palmeiras, 22'});

// ------------------------------------------------------------
// 5. Relacionamento MESMO_ENDERECO
// Simula a saída de um job de enriquecimento de endereços.
// f1-f2: endereço idêntico. f2-f4: numeração consecutiva no
// mesmo logradouro (heurística de proximidade, não string
// exata) — propositalmente SEM aresta direta f1-f4, para que
// a Q5 precise encontrar o caminho indireto de 2 saltos.
// ------------------------------------------------------------
MATCH (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'}), (f2:Fornecedor {ni_fornecedor:'23.456.789/0001-11'})
CREATE (f1)-[:MESMO_ENDERECO]->(f2);

MATCH (f2:Fornecedor {ni_fornecedor:'23.456.789/0001-11'}), (f4:Fornecedor {ni_fornecedor:'45.678.901/0001-33'})
CREATE (f2)-[:MESMO_ENDERECO]->(f4);

// ------------------------------------------------------------
// 6. Nós Contrato (10) + relacionamentos CONTRATOU / FORNECEU / DE_MODALIDADE
// C1/C2: mesmo fornecedor (F1) e mesmo órgão (O1), objeto quase
//        idêntico, 13 dias de intervalo → padrão de fracionamento (Q7)
// C5:    F2 (mesmo endereço de F1) também contrata com O1 na
//        mesma janela → reforça o sinal de risco (Q4)
// F1 contrata com O1, O2 e O3 → fornecedor multiórgão (Q3)
// ------------------------------------------------------------
MATCH (o1:OrgaoPublico {cnpj:'00.000.000/0001-91'}), (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'}), (m2:Modalidade {id_modalidade:2})
CREATE (c1:Contrato {id_contrato_pncp:'PNCP-2026-000001', numero_contrato:'001/2026', processo:'PROC-001/2026', objeto_contrato:'Aquisição de material de escritório', valor_inicial:9800.00, valor_global:9800.00, valor_parcelas:9800.00, data_assinatura:date('2026-03-05'), data_vigencia_inicio:date('2026-03-06'), data_vigencia_fim:date('2026-09-06'), data_publicacao:date('2026-03-08')})
CREATE (o1)-[:CONTRATOU]->(c1)
CREATE (f1)-[:FORNECEU]->(c1)
CREATE (c1)-[:DE_MODALIDADE]->(m2);

MATCH (o1:OrgaoPublico {cnpj:'00.000.000/0001-91'}), (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'}), (m2:Modalidade {id_modalidade:2})
CREATE (c2:Contrato {id_contrato_pncp:'PNCP-2026-000002', numero_contrato:'002/2026', processo:'PROC-002/2026', objeto_contrato:'Aquisição de material de expediente', valor_inicial:9700.00, valor_global:9700.00, valor_parcelas:9700.00, data_assinatura:date('2026-03-18'), data_vigencia_inicio:date('2026-03-19'), data_vigencia_fim:date('2026-09-19'), data_publicacao:date('2026-03-20')})
CREATE (o1)-[:CONTRATOU]->(c2)
CREATE (f1)-[:FORNECEU]->(c2)
CREATE (c2)-[:DE_MODALIDADE]->(m2);

MATCH (o2:OrgaoPublico {cnpj:'11.111.111/0001-22'}), (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'}), (m1:Modalidade {id_modalidade:1})
CREATE (c3:Contrato {id_contrato_pncp:'PNCP-2026-000003', numero_contrato:'003/2026', processo:'PROC-003/2026', objeto_contrato:'Serviços de manutenção predial', valor_inicial:150000.00, valor_global:150000.00, valor_parcelas:12500.00, data_assinatura:date('2026-02-10'), data_vigencia_inicio:date('2026-02-15'), data_vigencia_fim:date('2027-02-15'), data_publicacao:date('2026-02-18')})
CREATE (o2)-[:CONTRATOU]->(c3)
CREATE (f1)-[:FORNECEU]->(c3)
CREATE (c3)-[:DE_MODALIDADE]->(m1);

MATCH (o3:OrgaoPublico {cnpj:'22.222.222/0001-33'}), (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'}), (m1:Modalidade {id_modalidade:1})
CREATE (c4:Contrato {id_contrato_pncp:'PNCP-2026-000004', numero_contrato:'004/2026', processo:'PROC-004/2026', objeto_contrato:'Fornecimento de equipamentos de informática', valor_inicial:220000.00, valor_global:220000.00, valor_parcelas:220000.00, data_assinatura:date('2026-01-20'), data_vigencia_inicio:date('2026-01-25'), data_vigencia_fim:date('2026-07-25'), data_publicacao:date('2026-01-28')})
CREATE (o3)-[:CONTRATOU]->(c4)
CREATE (f1)-[:FORNECEU]->(c4)
CREATE (c4)-[:DE_MODALIDADE]->(m1);

MATCH (o1:OrgaoPublico {cnpj:'00.000.000/0001-91'}), (f2:Fornecedor {ni_fornecedor:'23.456.789/0001-11'}), (m2:Modalidade {id_modalidade:2})
CREATE (c5:Contrato {id_contrato_pncp:'PNCP-2026-000005', numero_contrato:'005/2026', processo:'PROC-005/2026', objeto_contrato:'Aquisição de material de escritório', valor_inicial:9900.00, valor_global:9900.00, valor_parcelas:9900.00, data_assinatura:date('2026-03-07'), data_vigencia_inicio:date('2026-03-08'), data_vigencia_fim:date('2026-09-08'), data_publicacao:date('2026-03-10')})
CREATE (o1)-[:CONTRATOU]->(c5)
CREATE (f2)-[:FORNECEU]->(c5)
CREATE (c5)-[:DE_MODALIDADE]->(m2);

MATCH (o2:OrgaoPublico {cnpj:'11.111.111/0001-22'}), (f3:Fornecedor {ni_fornecedor:'34.567.890/0001-22'}), (m1:Modalidade {id_modalidade:1})
CREATE (c6:Contrato {id_contrato_pncp:'PNCP-2026-000006', numero_contrato:'006/2026', processo:'PROC-006/2026', objeto_contrato:'Obra de reforma do prédio anexo', valor_inicial:980000.00, valor_global:980000.00, valor_parcelas:163333.33, data_assinatura:date('2026-01-15'), data_vigencia_inicio:date('2026-01-20'), data_vigencia_fim:date('2026-12-20'), data_publicacao:date('2026-01-25')})
CREATE (o2)-[:CONTRATOU]->(c6)
CREATE (f3)-[:FORNECEU]->(c6)
CREATE (c6)-[:DE_MODALIDADE]->(m1);

MATCH (o3:OrgaoPublico {cnpj:'22.222.222/0001-33'}), (f3:Fornecedor {ni_fornecedor:'34.567.890/0001-22'}), (m1:Modalidade {id_modalidade:1})
CREATE (c7:Contrato {id_contrato_pncp:'PNCP-2026-000007', numero_contrato:'007/2026', processo:'PROC-007/2026', objeto_contrato:'Serviços de pintura e reparos', valor_inicial:75000.00, valor_global:75000.00, valor_parcelas:25000.00, data_assinatura:date('2026-02-25'), data_vigencia_inicio:date('2026-03-01'), data_vigencia_fim:date('2026-09-01'), data_publicacao:date('2026-03-03')})
CREATE (o3)-[:CONTRATOU]->(c7)
CREATE (f3)-[:FORNECEU]->(c7)
CREATE (c7)-[:DE_MODALIDADE]->(m1);

MATCH (o2:OrgaoPublico {cnpj:'11.111.111/0001-22'}), (f4:Fornecedor {ni_fornecedor:'45.678.901/0001-33'}), (m2:Modalidade {id_modalidade:2})
CREATE (c8:Contrato {id_contrato_pncp:'PNCP-2026-000008', numero_contrato:'008/2026', processo:'PROC-008/2026', objeto_contrato:'Aquisição de suprimentos de informática', valor_inicial:8500.00, valor_global:8500.00, valor_parcelas:8500.00, data_assinatura:date('2026-03-02'), data_vigencia_inicio:date('2026-03-03'), data_vigencia_fim:date('2026-09-03'), data_publicacao:date('2026-03-05')})
CREATE (o2)-[:CONTRATOU]->(c8)
CREATE (f4)-[:FORNECEU]->(c8)
CREATE (c8)-[:DE_MODALIDADE]->(m2);

MATCH (o3:OrgaoPublico {cnpj:'22.222.222/0001-33'}), (f5:Fornecedor {ni_fornecedor:'78.912.345-00'}), (m2:Modalidade {id_modalidade:2})
CREATE (c9:Contrato {id_contrato_pncp:'PNCP-2026-000009', numero_contrato:'009/2026', processo:'PROC-009/2026', objeto_contrato:'Serviço de consultoria jurídica pontual', valor_inicial:4200.00, valor_global:4200.00, valor_parcelas:4200.00, data_assinatura:date('2026-03-10'), data_vigencia_inicio:date('2026-03-11'), data_vigencia_fim:date('2026-06-11'), data_publicacao:date('2026-03-12')})
CREATE (o3)-[:CONTRATOU]->(c9)
CREATE (f5)-[:FORNECEU]->(c9)
CREATE (c9)-[:DE_MODALIDADE]->(m2);

MATCH (o1:OrgaoPublico {cnpj:'00.000.000/0001-91'}), (f4:Fornecedor {ni_fornecedor:'45.678.901/0001-33'}), (m1:Modalidade {id_modalidade:1})
CREATE (c10:Contrato {id_contrato_pncp:'PNCP-2026-000010', numero_contrato:'010/2026', processo:'PROC-010/2026', objeto_contrato:'Contratação de serviço de limpeza', valor_inicial:130000.00, valor_global:130000.00, valor_parcelas:10833.33, data_assinatura:date('2026-02-01'), data_vigencia_inicio:date('2026-02-05'), data_vigencia_fim:date('2027-02-05'), data_publicacao:date('2026-02-08')})
CREATE (o1)-[:CONTRATOU]->(c10)
CREATE (f4)-[:FORNECEU]->(c10)
CREATE (c10)-[:DE_MODALIDADE]->(m1);

// ============================================================
// QUERIES — Etapa 1 (Q1 a Q7)
// ============================================================

// ------------------------------------------------------------
// Q1 — Contratos de um órgão, ordenados por valor (filtro: cnpj
// do órgão; ordenação: valor_global desc)
// ------------------------------------------------------------
MATCH (o:OrgaoPublico {cnpj:'00.000.000/0001-91'})-[:CONTRATOU]->(c:Contrato)
RETURN o.nome AS orgao, c.numero_contrato AS contrato, c.objeto_contrato AS objeto, c.valor_global AS valor, c.data_assinatura AS data
ORDER BY c.valor_global DESC;

// ------------------------------------------------------------
// Q2 — Fornecedores de um órgão, valor total agregado (filtro:
// cnpj do órgão; agregação: SUM(valor_global) por fornecedor)
// ------------------------------------------------------------
MATCH (o:OrgaoPublico {cnpj:'00.000.000/0001-91'})-[:CONTRATOU]->(c:Contrato)<-[:FORNECEU]-(f:Fornecedor)
RETURN f.nome AS fornecedor, count(c) AS qtd_contratos, sum(c.valor_global) AS valor_total
ORDER BY valor_total DESC;

// ------------------------------------------------------------
// Q3 — Fornecedores multiórgão (conta órgãos distintos por
// fornecedor; filtro: mais de 1 órgão)
// ------------------------------------------------------------
MATCH (f:Fornecedor)-[:FORNECEU]->(:Contrato)<-[:CONTRATOU]-(o:OrgaoPublico)
WITH f, count(DISTINCT o) AS qtd_orgaos
WHERE qtd_orgaos > 1
RETURN f.nome AS fornecedor, qtd_orgaos
ORDER BY qtd_orgaos DESC;

// ------------------------------------------------------------
// Q4 — Rede de mesmo endereço: fornecedores diretamente
// conectados que também contrataram com o mesmo órgão
// (travessia de 1 salto em MESMO_ENDERECO + filtro de órgão
// em comum)
// ------------------------------------------------------------
MATCH (f1:Fornecedor)-[:MESMO_ENDERECO]-(f2:Fornecedor)
MATCH (f1)-[:FORNECEU]->(:Contrato)<-[:CONTRATOU]-(o:OrgaoPublico)-[:CONTRATOU]->(:Contrato)<-[:FORNECEU]-(f2)
RETURN DISTINCT f1.nome AS fornecedor_a, f2.nome AS fornecedor_b, f1.endereco AS endereco, o.nome AS orgao_em_comum;

// ------------------------------------------------------------
// Q5 — Menor caminho entre dois fornecedores na rede de
// MESMO_ENDERECO (travessia indireta, mesmo sem aresta direta)
// ------------------------------------------------------------
MATCH p = shortestPath(
  (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'})-[:MESMO_ENDERECO*]-(f2:Fornecedor {ni_fornecedor:'45.678.901/0001-33'})
)
RETURN [n IN nodes(p) | n.nome] AS cadeia_de_vinculos, length(p) AS saltos;

// ------------------------------------------------------------
// Q6 — Top fornecedores por modalidade (filtro: nome da
// modalidade; ordenação: valor total desc)
// ------------------------------------------------------------
MATCH (f:Fornecedor)-[:FORNECEU]->(c:Contrato)-[:DE_MODALIDADE]->(m:Modalidade {nome:'Pregão Eletrônico'})
RETURN f.nome AS fornecedor, sum(c.valor_global) AS valor_total
ORDER BY valor_total DESC;

// ------------------------------------------------------------
// Q7 — Possível fracionamento: mesmo fornecedor + mesmo órgão
// com múltiplos contratos dentro de uma janela de 30 dias
// (travessia + filtro temporal; filtro: count > 1)
// ------------------------------------------------------------
MATCH (f:Fornecedor)-[:FORNECEU]->(c:Contrato)<-[:CONTRATOU]-(o:OrgaoPublico)
WITH f, o, c
ORDER BY c.data_assinatura
WITH f, o, collect(c) AS contratos
UNWIND range(0, size(contratos)-2) AS i
WITH f, o, contratos[i] AS c1, contratos[i+1] AS c2
WHERE duration.between(c1.data_assinatura, c2.data_assinatura).days <= 30
RETURN f.nome AS fornecedor, o.nome AS orgao, c1.numero_contrato AS contrato_1, c2.numero_contrato AS contrato_2,
       duration.between(c1.data_assinatura, c2.data_assinatura).days AS dias_entre_contratos;
