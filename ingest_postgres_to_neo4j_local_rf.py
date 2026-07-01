"""
ingest_postgres_to_neo4j_local_rf.py
RadarPNCP — versão com endereço via base LOCAL da Receita Federal
(Dados Abertos do CNPJ, carregados no Postgres por uma ferramenta como
aphonsoar/Receita_Federal_do_Brasil_-_Dados_Publicos_CNPJ), em vez da BrasilAPI.

Vantagem sobre a versão anterior: o enriquecimento de endereço deixa de ser
uma chamada HTTP por fornecedor (sujeita a rate limit) e passa a ser um JOIN
no banco — sem limite prático de quantidade, sem delay, sem dependência de
rede externa.

PRÉ-REQUISITOS / SUPOSIÇÕES (confirme antes de rodar):
  1. As tabelas da Receita Federal (estabelecimento, empresa, etc.) foram
     carregadas no MESMO Postgres do pncp_db. Se você carregou num banco
     separado, ou usou SQLite (rictom/cnpj-sqlite), este script não funciona
     direto — você precisaria de postgres_fdw, ou fazer o cruzamento em
     pandas lendo as duas fontes separadamente (me chama que eu adapto).
  2. Os nomes de tabela/coluna abaixo seguem o layout padrão da Receita
     Federal (cnpj_basico, cnpj_ordem, cnpj_dv, tipo_logradouro, logradouro,
     numero, bairro, municipio, uf) — é o que a maioria das ferramentas de
     ETL preserva, mas CONFIRME contra o schema real que a sua ferramenta
     gerou antes de rodar.
  3. cnpj_ordem e cnpj_dv precisam estar armazenados como texto (com zeros
     à esquerda), não como inteiro — senão a concatenação quebra o JOIN.

Pré-requisitos Python:
    pip install psycopg2-binary neo4j --break-system-packages
    (requests não é mais necessário — sem chamada de API)
"""

import psycopg2
import psycopg2.extras
from neo4j import GraphDatabase

# ---------------- Config ----------------
PG_DSN = dict(host="localhost", port=5432, dbname="pncp_db", user="postgres", password="postgres")
NEO4J_URI = "bolt://localhost:7687"
NEO4J_AUTH = ("neo4j", "radarpncp123")

LIMITE_CONTRATOS = 200             # sem API de por meio, pode subir esse número com tranquilidade
TOP_FORNECEDORES_MULTIORGAO = 80   # fornecedores "interessantes" (>1 órgão) considerados antes do LIMIT

# ---------------- 1. Extração + enriquecimento, tudo em uma query ----------------
# A diferença central da versão anterior: o endereço já vem pronto do JOIN
# com `estabelecimento`, não de uma chamada externa.
SQL_BASE = """
WITH top_fornecedores AS (
    SELECT cnpj_contratada,
           count(DISTINCT orgao_entidade_id) AS qtd_orgaos
    FROM fato_contratos
    GROUP BY cnpj_contratada
    HAVING count(DISTINCT orgao_entidade_id) > 1
    ORDER BY qtd_orgaos DESC, sum(valor_global) DESC
    LIMIT %(top_fornecedores)s
)
SELECT
    f.id_contrato_pncp, f.numero_contrato, f.processo, f.objeto_contrato,
    f.valor_inicial, f.valor_global, f.valor_parcelas,
    f.data_assinatura, f.data_vigencia_inicio, f.data_vigencia_fim, f.data_publicacao,
    o.orgao_entidade_id  AS orgao_cnpj,   o.orgao_entidade_nome AS orgao_nome,
    o.codigo_unidade,    o.nome_unidade,
    fo.cnpj_contratada   AS fornecedor_ni, fo.nome_contratada   AS fornecedor_nome,
    m.id_modalidade,     m.modalidade_nome,
    TRIM(CONCAT_WS(' ', est.tipo_logradouro, est.logradouro))  AS rf_rua,
    est.numero    AS rf_numero,
    est.bairro    AS rf_bairro,
    est.municipio AS rf_municipio,
    est.uf        AS rf_uf
FROM fato_contratos f
JOIN top_fornecedores  tf  ON tf.cnpj_contratada  = f.cnpj_contratada
JOIN dim_orgaos        o   ON o.orgao_entidade_id = f.orgao_entidade_id
JOIN dim_fornecedores  fo  ON fo.cnpj_contratada  = f.cnpj_contratada
JOIN dim_modalidades   m   ON m.id_modalidade     = f.id_modalidade
LEFT JOIN estabelecimento est
       ON regexp_replace(fo.cnpj_contratada, '[^0-9]', '', 'g')
          = (est.cnpj_basico || est.cnpj_ordem || est.cnpj_dv)
ORDER BY f.valor_global DESC
LIMIT %(limite)s;
"""
# Nota: o JOIN casa pelo CNPJ completo (14 dígitos = cnpj_basico + cnpj_ordem
# + cnpj_dv), então já aponta pro estabelecimento exato contratado (matriz
# OU filial) — não precisa filtrar identificador_matriz_filial.
# Fornecedor pessoa física (CPF, 11 dígitos) simplesmente não casa com nada
# em `estabelecimento` (que só tem CNPJ) — LEFT JOIN garante NULL nesse caso,
# igual ao comportamento da versão com BrasilAPI.

def montar_endereco(r):
    if not r["rf_rua"] and not r["rf_municipio"]:
        return None
    return f"{r['rf_rua']}, {r['rf_numero'] or ''} - {r['rf_bairro'] or ''}, {r['rf_municipio'] or ''}/{r['rf_uf'] or ''}"

def extrair_contratos():
    params = {"limite": LIMITE_CONTRATOS, "top_fornecedores": TOP_FORNECEDORES_MULTIORGAO}
    with psycopg2.connect(**PG_DSN) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(SQL_BASE, params)
            registros = cur.fetchall()
    for r in registros:
        r["endereco"] = montar_endereco(r)
    return registros

# ---------------- 2. Carga no Neo4j ----------------
CYPHER_INDEX = "CREATE INDEX fornecedor_endereco IF NOT EXISTS FOR (f:Fornecedor) ON (f.endereco)"

CYPHER_UPSERT = """
MERGE (o:OrgaoPublico {cnpj: $orgao_cnpj})
  ON CREATE SET o.nome = $orgao_nome, o.codigo_unidade = $codigo_unidade, o.nome_unidade = $nome_unidade

MERGE (f:Fornecedor {ni_fornecedor: $fornecedor_ni})
  ON CREATE SET f.nome = $fornecedor_nome,
                f.tipo_pessoa = CASE WHEN size(replace(replace($fornecedor_ni,'.',''),'-','')) = 14
                                     THEN 'PJ' ELSE 'PF' END,
                f.endereco = $endereco

MERGE (m:Modalidade {id_modalidade: $id_modalidade})
  ON CREATE SET m.nome = $modalidade_nome

MERGE (c:Contrato {id_contrato_pncp: $id_contrato_pncp})
  ON CREATE SET c.numero_contrato = $numero_contrato, c.processo = $processo,
                c.objeto_contrato = $objeto_contrato,
                c.valor_inicial = $valor_inicial, c.valor_global = $valor_global,
                c.valor_parcelas = $valor_parcelas,
                c.data_assinatura = date($data_assinatura),
                c.data_vigencia_inicio = date($data_vigencia_inicio),
                c.data_vigencia_fim = date($data_vigencia_fim),
                c.data_publicacao = date($data_publicacao)

MERGE (o)-[:CONTRATOU]->(c)
MERGE (f)-[:FORNECEU]->(c)
MERGE (c)-[:DE_MODALIDADE]->(m)
"""

CYPHER_MESMO_ENDERECO = """
MATCH (f1:Fornecedor), (f2:Fornecedor)
WHERE f1.ni_fornecedor < f2.ni_fornecedor
  AND f1.endereco IS NOT NULL AND f1.endereco = f2.endereco
MERGE (f1)-[:MESMO_ENDERECO]->(f2)
RETURN count(*) AS arestas_criadas
"""

def carregar_no_neo4j(registros):
    driver = GraphDatabase.driver(NEO4J_URI, auth=NEO4J_AUTH)
    with driver.session() as session:
        session.run(CYPHER_INDEX)
        for r in registros:
            session.run(CYPHER_UPSERT, {
                "orgao_cnpj": r["orgao_cnpj"], "orgao_nome": r["orgao_nome"],
                "codigo_unidade": r["codigo_unidade"], "nome_unidade": r["nome_unidade"],
                "fornecedor_ni": r["fornecedor_ni"], "fornecedor_nome": r["fornecedor_nome"],
                "endereco": r["endereco"],
                "id_modalidade": r["id_modalidade"], "modalidade_nome": r["modalidade_nome"],
                "id_contrato_pncp": r["id_contrato_pncp"], "numero_contrato": r["numero_contrato"],
                "processo": r["processo"], "objeto_contrato": r["objeto_contrato"],
                "valor_inicial": float(r["valor_inicial"] or 0),
                "valor_global": float(r["valor_global"] or 0),
                "valor_parcelas": float(r["valor_parcelas"] or 0),
                "data_assinatura": str(r["data_assinatura"]),
                "data_vigencia_inicio": str(r["data_vigencia_inicio"]),
                "data_vigencia_fim": str(r["data_vigencia_fim"]),
                "data_publicacao": str(r["data_publicacao"]),
            })
            print(f"  + {r['fornecedor_nome'][:40]:40s} -> {r['orgao_nome'][:30]:30s} | endereco: {r['endereco'] or '—'}")

        print("Conectando fornecedores com o mesmo endereço (MESMO_ENDERECO)...")
        result = session.run(CYPHER_MESMO_ENDERECO).single()
        print(f"  arestas MESMO_ENDERECO criadas: {result['arestas_criadas']}")
    driver.close()

# ---------------- main ----------------
if __name__ == "__main__":
    print(f"Extraindo até {LIMITE_CONTRATOS} contratos reais (endereço via base local da RF)...")
    registros = extrair_contratos()
    distintos = len({r["fornecedor_ni"] for r in registros})
    com_endereco = sum(1 for r in registros if r["endereco"])
    print(f"  {len(registros)} contratos, {distintos} fornecedores distintos, "
          f"{com_endereco} contratos com endereço encontrado na base da RF")
    carregar_no_neo4j(registros)
    print("Concluído. Veja em http://localhost:7474")
