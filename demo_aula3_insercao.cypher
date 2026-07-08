// ============================================================
// RadarPNCP — DEMO AO VIVO (Aula 3)
// Inserção em tempo real exigida pelo enunciado:
// "demonstração prática da inserção de um registro e da
//  execução das consultas principais".
//
// ARQUIVO SEPARADO DE PROPÓSITO: o seed principal
// (etapa3_poc_radarpncp.cypher) deve ser carregado SEM este
// contrato, para que o antes/depois da demo funcione.
//
// Roteiro (3 passos, ~2 minutos):
//   1. Rodar a Q7 no Browser → retorna 1 par
//      (001/2026 + 002/2026, 13 dias, R$ 19.500).
//   2. Executar o bloco abaixo — insere o contrato 011/2026:
//      mesmo órgão (IFA), mesmo fornecedor (Alfa Serviços),
//      R$ 9.600 (sob o limiar), assinado 7 dias após o 002/2026.
//   3. Rodar a Q7 novamente → retorna 3 pares
//      (001+002, 001+011, 002+011): o detector acusou o novo
//      contrato no instante em que ele entrou no grafo.
//
// Frase de fechamento sugerida: "o auditor não precisou
// procurar — o grafo acusou na hora em que o contrato entrou."
//
// Para repetir a demo: rodar o bloco de limpeza no fim deste
// arquivo (remove só o C11) e recomeçar do passo 1.
// ============================================================

MATCH (o1:OrgaoPublico {cnpj:'00.000.000/0001-91'}),
      (f1:Fornecedor {ni_fornecedor:'12.345.678/0001-00'}),
      (m2:Modalidade {id_modalidade:2})
CREATE (c11:Contrato {id_contrato_pncp:'PNCP-2026-000011',
  numero_contrato:'011/2026', processo:'PROC-011/2026',
  objeto_contrato:'Aquisição de material de papelaria',
  valor_inicial:9600.00, valor_global:9600.00, valor_parcelas:9600.00,
  data_assinatura:date('2026-03-25'),
  data_vigencia_inicio:date('2026-03-26'),
  data_vigencia_fim:date('2026-09-26'),
  data_publicacao:date('2026-03-27')})
CREATE (o1)-[:CONTRATOU]->(c11)
CREATE (f1)-[:FORNECEU]->(c11)
CREATE (c11)-[:DE_MODALIDADE]->(m2);

// ------------------------------------------------------------
// Limpeza da demo (remove APENAS o contrato inserido acima,
// preservando o seed) — para reexecutar o antes/depois:
// ------------------------------------------------------------
// MATCH (c:Contrato {id_contrato_pncp:'PNCP-2026-000011'})
// DETACH DELETE c;
