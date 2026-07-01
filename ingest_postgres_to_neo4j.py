"""
ingest_postgres_to_neo4j.py
RadarPNCP — versão híbrida: contratos reais (Postgres Gold) + endereço
real de fornecedores PJ via Receita Federal (espelhado pela BrasilAPI).

Pré-requisitos:
    pip install psycopg2-binary requests neo4j --break-system-packages

Antes de rodar:
  - Confirme os nomes de coluna das dimensões (orgao_nome, codigo_unidade,
    nome_unidade, fornecedor_nome, modalidade_nome) contra o seu gold_setup.py —
    usei os nomes do dicionário de dados do README do Lab01_PART1_5479786,
    mas se você renomeou algo lá, ajuste o SQL abaixo.
  - A BrasilAPI é pública e gratuita, sem autenticação, mas tem rate limit
    informal — por isso o delay entre chamadas e o cache em memória.
  - Não testei a chamada à BrasilAPI neste ambiente (minha rede aqui é
    restrita a um allowlist que não inclui brasilapi.com.br) — teste no
    seu notebook antes de confiar no resultado.
"""

import time
import psycopg2
import psycopg2.extras
import requests
from neo4j import GraphDatabase

# ---------------- Config ----------------
PG_DSN = dict(host="localhost", port=5432, dbname="pncp_db", user="postgres", password="postgres")
NEO4J_URI = "bolt://localhost:7687"
NEO4J_AUTH = ("neo4j", "radarpncp123")

LIMITE_CONTRATOS = 200      # cap final de contratos — ainda é uma PoC, não o pipeline de 3,65M
TOP_FORNECEDORES_MULTIORGAO = 80  # quantos fornecedores "interessantes" (>1 órgão) considerar antes do LIMIT
BRASILAPI_DELAY_S = 1.3     # segundos entre chamadas — respeita o rate limit público

# ---------------- 1. Extração do Postgres (Gold real) ----------------
# Em vez de simplesmente pegar os 200 contratos de maior valor (o que poderia
# devolver 200 fornecedores distintos com 1 contrato cada, deixando Q3 vazia),
# primeiro seleciona os fornecedores que JÁ são multiórgão nos dados reais,
# e só então pega os contratos deles. Isso garante que a amostra alimenta
# Q3 (multiórgão) de verdade, e dá à BrasilAPI uma população onde vínculos
# de mesmo endereço (Q4/Q5) são mais prováveis de aparecer organicamente.
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
    m.id_modalidade,     m.modalidade_nome
FROM fato_contratos f
JOIN top_fornecedores  tf ON tf.cnpj_contratada  = f.cnpj_contratada
JOIN dim_orgaos        o  ON o.orgao_entidade_id = f.orgao_entidade_id
JOIN dim_fornecedores  fo ON fo.cnpj_contratada  = f.cnpj_contratada
JOIN dim_modalidades   m  ON m.id_modalidade     = f.id_modalidade
ORDER BY f.valor_global DESC
LIMIT %(limite)s;
"""

def extrair_contratos():
    params = {"limite": LIMITE_CONTRATOS, "top_fornecedores": TOP_FORNECEDORES_MULTIORGAO}
    with psycopg2.connect(**PG_DSN) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(SQL_BASE, params)
            return cur.fetchall()

# ---------------- 2. Enriquecimento de endereço (Receita Federal via BrasilAPI) ----------------
_cache_endereco = {}

def buscar_endereco_receita(cnpj_ou_cpf: str):
    """Consulta o CNPJ na BrasilAPI (espelha o CNPJ público da Receita Federal).
    Fornecedor pessoa física (CPF) não tem esse registro público — retorna None,
    e o nó fica sem endereco (não participa de MESMO_ENDERECO)."""
    doc = "".join(ch for ch in (cnpj_ou_cpf or "") if ch.isdigit())
    if len(doc) != 14:
        return None
    if doc in _cache_endereco:
        return _cache_endereco[doc]
    try:
        resp = requests.get(f"https://brasilapi.com.br/api/cnpj/v1/{doc}", timeout=10)
        time.sleep(BRASILAPI_DELAY_S)
        if resp.status_code != 200:
            _cache_endereco[doc] = None
            return None
        d = resp.json()
        partes = [
            d.get("descricao_tipo_de_logradouro", "") or "",
            d.get("logradouro", "") or "",
        ]
        rua = " ".join(p for p in partes if p).strip()
        endereco = f"{rua}, {d.get('numero','')} - {d.get('bairro','')}, {d.get('municipio','')}/{d.get('uf','')}"
        _cache_endereco[doc] = endereco
        return endereco
    except requests.RequestException as e:
        print(f"  [aviso] falha ao consultar CNPJ {doc}: {e}")
        _cache_endereco[doc] = None
        return None

# ---------------- 3. Carga no Neo4j ----------------
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
        for r in registros:
            endereco = buscar_endereco_receita(r["fornecedor_ni"])
            session.run(CYPHER_UPSERT, {
                "orgao_cnpj": r["orgao_cnpj"], "orgao_nome": r["orgao_nome"],
                "codigo_unidade": r["codigo_unidade"], "nome_unidade": r["nome_unidade"],
                "fornecedor_ni": r["fornecedor_ni"], "fornecedor_nome": r["fornecedor_nome"],
                "endereco": endereco,
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
            print(f"  + {r['fornecedor_nome'][:40]:40s} -> {r['orgao_nome'][:30]:30s} | endereco: {endereco or '—'}")

        print("Conectando fornecedores com o mesmo endereço (MESMO_ENDERECO)...")
        result = session.run(CYPHER_MESMO_ENDERECO).single()
        print(f"  arestas MESMO_ENDERECO criadas: {result['arestas_criadas']}")
    driver.close()

# ---------------- main ----------------
if __name__ == "__main__":
    print(f"Extraindo até {LIMITE_CONTRATOS} contratos reais do Postgres...")
    registros = extrair_contratos()
    distintos = len({r["fornecedor_ni"] for r in registros})
    print(f"  {len(registros)} contratos, {distintos} fornecedores distintos")
    carregar_no_neo4j(registros)
    print("Concluído. Veja em http://localhost:7474")
