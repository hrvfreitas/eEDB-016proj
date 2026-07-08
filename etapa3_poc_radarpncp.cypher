// ============================================================
// RadarPNCP — Etapa 3: Implementação e Validação (PoC)
// PECE/USP eEDB-016 — Repositórios de Dados e NoSQL
// Tecnologia: Neo4j (grafos)
// ============================================================
// Como executar:
//   cypher-shell -u neo4j -p <senha> -f etapa3_poc_radarpncp.cypher
// ou colar cada bloco no Neo4j Browser.
//
// Revisão 2026-07: correções aplicadas —
//   Q4: deduplicação de pares espelhados (A,B)/(B,A)
//   Q6: inclui contratos assinados no MESMO dia; datas via date();
//       valores via coalesce(); comentário do cabeçalho atualizado
//   Q7: duration.inDays no lugar de duration.between (que normaliza
//       em meses+dias e faria "1 mês e 5 dias" passar no filtro de
//       30 dias); adicionado filtro de valor sob o limiar de
//       dispensa — é o que diferencia Q7 (fracionamento) de Q6
//       (recorrência)
//   Geral: '#' não é comentário em Cypher → '//'
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
//        idêntico, 13 dias de intervalo, valores sob o limiar
//        de dispensa → padrão de fracionamento (Q6 acha a
//        recorrência; Q7 confirma com o filtro de valor)
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
// Rev.: dedup de pares espelhados — o match não-direcionado
// casa cada aresta nos dois sentidos, gerando (A,B) e (B,A);
// a ordenação por chave garante uma linha por par.
// ------------------------------------------------------------
MATCH (f1:Fornecedor)-[:MESMO_ENDERECO]-(f2:Fornecedor)
WHERE f1.ni_fornecedor < f2.ni_fornecedor
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

// Q5 (visual) — o mesmo caminho, desenhado
MATCH p = shortestPath(
  (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'})-[:MESMO_ENDERECO*]-(f2:Fornecedor {ni_fornecedor:'45.678.901/0001-33'})
)
RETURN p;

// ------------------------------------------------------------
// Q6 — Recontratação em janela curta: mesmo órgão + mesmo
// fornecedor contratando de novo em até 30 dias — repetição
// sem justificativa aparente (estágio 1 do detector; a Q7
// refina com o filtro de valor).
// Rev.: dedup pela chave (não pela data) para incluir
// contratos assinados no MESMO dia — o caso mais escancarado;
// date() blinda contra datas armazenadas como string;
// coalesce() evita soma nula; abs() porque a ordem do par não
// é mais garantida pela data.
// ------------------------------------------------------------
MATCH (o:OrgaoPublico)-[:CONTRATOU]->(c1:Contrato)<-[:FORNECEU]-(f:Fornecedor),
      (o)-[:CONTRATOU]->(c2:Contrato)<-[:FORNECEU]-(f)
WHERE c1.id_contrato_pncp < c2.id_contrato_pncp
WITH o, f, c1, c2,
     abs(duration.inDays(date(c1.data_assinatura),
                         date(c2.data_assinatura)).days) AS dias
WHERE dias <= 30
RETURN o.nome             AS orgao,
       f.nome             AS fornecedor,
       c1.numero_contrato AS contrato_1, c1.data_assinatura AS data_1,
       c2.numero_contrato AS contrato_2, c2.data_assinatura AS data_2,
       dias               AS dias_entre_contratos,
       coalesce(c1.valor_global, 0) + coalesce(c2.valor_global, 0) AS valor_somado
ORDER BY dias ASC, valor_somado DESC;

// Q6 (visual) — o mesmo padrão, desenhado
MATCH p1 = (o:OrgaoPublico)-[:CONTRATOU]->(c1:Contrato)<-[:FORNECEU]-(f:Fornecedor),
      p2 = (o)-[:CONTRATOU]->(c2:Contrato)<-[:FORNECEU]-(f)
WHERE c1.id_contrato_pncp < c2.id_contrato_pncp
  AND abs(duration.inDays(date(c1.data_assinatura),
                          date(c2.data_assinatura)).days) <= 30
RETURN p1, p2;

// ------------------------------------------------------------
// Q7 — Possível fracionamento: refina a Q6 com o filtro de
// VALOR — ambos os contratos sob o limiar de dispensa
// (parâmetro de auditoria; R$ 10.000 nos dados de validação).
// A soma dos dois ultrapassa o limiar: indício de que uma
// compra foi dividida para escapar da licitação.
// Rev.: duration.inDays no lugar de duration.between — between
// normaliza em meses+dias e ".days" retorna só o componente de
// dias (ex.: 1 mês e 5 dias → days = 5, passando indevidamente
// no filtro de 30). inDays retorna o total em dias.
// ------------------------------------------------------------
MATCH (o:OrgaoPublico)-[:CONTRATOU]->(c1:Contrato)<-[:FORNECEU]-(f:Fornecedor),
      (o)-[:CONTRATOU]->(c2:Contrato)<-[:FORNECEU]-(f)
WHERE c1.id_contrato_pncp < c2.id_contrato_pncp
  AND coalesce(c1.valor_global, 0) < 10000
  AND coalesce(c2.valor_global, 0) < 10000
WITH o, f, c1, c2,
     abs(duration.inDays(date(c1.data_assinatura),
                         date(c2.data_assinatura)).days) AS dias
WHERE dias <= 30
RETURN f.nome             AS fornecedor,
       o.nome             AS orgao,
       c1.numero_contrato AS contrato_1, c1.valor_global AS valor_1,
       c2.numero_contrato AS contrato_2, c2.valor_global AS valor_2,
       dias               AS dias_entre_contratos,
       c1.valor_global + c2.valor_global AS valor_somado_acima_do_limiar
ORDER BY dias ASC;

// Q7 (visual) — os contratos gêmeos sob o limiar, desenhados
MATCH p1 = (o:OrgaoPublico)-[:CONTRATOU]->(c1:Contrato)<-[:FORNECEU]-(f:Fornecedor),
      p2 = (o)-[:CONTRATOU]->(c2:Contrato)<-[:FORNECEU]-(f)
WHERE c1.id_contrato_pncp < c2.id_contrato_pncp
  AND coalesce(c1.valor_global, 0) < 10000
  AND coalesce(c2.valor_global, 0) < 10000
  AND abs(duration.inDays(date(c1.data_assinatura),
                          date(c2.data_assinatura)).days) <= 30
RETURN p1, p2;
