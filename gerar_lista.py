import requests

# 1. Sites que já filtram anúncios (nossas fontes)
fontes = [
    "https://adaway.org/hosts.txt",
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
]

dominios_bloqueados = set()

print("Iniciando a coleta de domínios...")

for url in fontes:
    try:
        resposta = requests.get(url)
        linhas = resposta.text.splitlines()
        for linha in linhas:
            # Ignora comentários e linhas vazias
            if linha.startswith('#') or not linha.strip():
                continue
            # Pega apenas o nome do site (ex: 0.0.0.0 site-de-anuncios.com -> site-de-anuncios.com)
            partes = linha.split()
            if len(partes) > 1:
                dominio = partes[1]
                dominios_bloqueados.add(dominio)
    except:
        print(f"Erro ao baixar a lista: {url}")

# 2. Criar o arquivo final que os aparelhos vão ler
with open("minha_lista.txt", "w") as f:
    f.write("# LISTA DE BLOQUEIO DO MEU PROJETO\n")
    f.write(f"# Total de dominios: {len(dominios_bloqueados)}\n\n")
    for d in sorted(dominios_bloqueados):
        f.write(f"0.0.0.0 {d}\n")

print("Lista criada com sucesso!")
