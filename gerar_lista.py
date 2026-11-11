import re
import sys

import requests

# 1. Sites que já filtram anúncios (nossas fontes)
fontes = [
    "https://adaway.org/hosts.txt",
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts",
]

# Só aceitamos linhas que apontam o domínio para um destes IPs (bloqueio).
IPS_DE_BLOQUEIO = {"0.0.0.0", "127.0.0.1", "::", "::1"}

# Nomes locais que aparecem no cabeçalho dos arquivos hosts e NÃO devem ser bloqueados.
NOMES_LOCAIS = {
    "localhost",
    "localhost.localdomain",
    "local",
    "broadcasthost",
    "0.0.0.0",
    "ip6-localhost",
    "ip6-loopback",
    "ip6-localnet",
    "ip6-mcastprefix",
    "ip6-allnodes",
    "ip6-allrouters",
    "ip6-allhosts",
}

# Domínio válido: rótulos de letras/números/hífen/sublinhado separados por ponto,
# com pelo menos um ponto (ex: anuncio.com).
DOMINIO_VALIDO = re.compile(
    r"^(?=.{1,253}$)([a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z0-9-]{2,63}$"
)

# Mínimo de domínios que cada fonte precisa ter; abaixo disso algo deu errado.
MINIMO_POR_FONTE = 1000


def extrair_dominios(texto):
    dominios = set()
    for linha in texto.splitlines():
        # Remove comentários (inclusive no fim da linha) e espaços
        linha = linha.split("#", 1)[0].strip()
        if not linha:
            continue
        partes = linha.split()
        if len(partes) < 2 or partes[0] not in IPS_DE_BLOQUEIO:
            continue
        # Uma linha pode ter vários domínios: 0.0.0.0 a.com b.com
        for dominio in partes[1:]:
            dominio = dominio.lower().rstrip(".")
            if dominio in NOMES_LOCAIS or not DOMINIO_VALIDO.match(dominio):
                continue
            dominios.add(dominio)
    return dominios


dominios_bloqueados = set()

print("Iniciando a coleta de domínios...")

for url in fontes:
    try:
        resposta = requests.get(url, timeout=60)
        resposta.raise_for_status()
    except requests.RequestException as erro:
        # Falha o build em vez de publicar uma lista incompleta.
        sys.exit(f"Erro ao baixar a lista {url}: {erro}")

    encontrados = extrair_dominios(resposta.text)
    if len(encontrados) < MINIMO_POR_FONTE:
        sys.exit(
            f"A fonte {url} retornou só {len(encontrados)} domínios; "
            "parece inválida, abortando."
        )
    print(f"{url}: {len(encontrados)} domínios")
    dominios_bloqueados |= encontrados

# 2. Criar o arquivo final que os aparelhos vão ler
with open("minha_lista.txt", "w", encoding="utf-8") as f:
    f.write("# LISTA DE BLOQUEIO DO MEU PROJETO\n")
    f.write(f"# Total de dominios: {len(dominios_bloqueados)}\n\n")
    for d in sorted(dominios_bloqueados):
        f.write(f"0.0.0.0 {d}\n")

print(f"Lista criada com sucesso! Total: {len(dominios_bloqueados)} domínios")
