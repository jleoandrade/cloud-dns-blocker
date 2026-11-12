# 🛡️ cloud-dns-blocker

Lista de bloqueio de anúncios e rastreadores, no formato *hosts*, atualizada automaticamente todos os dias pelo GitHub Actions.

## 🚀 Como usar

Adicione o link abaixo como lista de bloqueio no seu bloqueador (AdGuard Home, Pi-hole, NextDNS etc.):

```
https://raw.githubusercontent.com/jleoandrade/cloud-dns-blocker/refs/heads/main/minha_lista.txt
```

## 📊 O que este projeto faz

- Baixa diariamente os domínios das fontes listadas abaixo.
- Mantém só entradas de bloqueio válidas: descarta nomes locais (`localhost`, `broadcasthost`, `ip6-*` etc.) e linhas malformadas.
- Junta tudo, remove duplicatas e ordena, gerando o arquivo `minha_lista.txt`.
- Se alguma fonte falhar ou vier incompleta, a atualização é abortada e a lista anterior continua publicada.

## 📚 Fontes

| Fonte | Link | Licença |
|---|---|---|
| AdAway | <https://adaway.org/hosts.txt> | [CC BY 3.0](https://creativecommons.org/licenses/by/3.0/) |
| StevenBlack/hosts (unificado) | <https://github.com/StevenBlack/hosts> | [MIT](https://github.com/StevenBlack/hosts/blob/master/license.txt) |

O arquivo unificado do StevenBlack agrega várias outras listas; os créditos e licenças de cada uma estão no [repositório dele](https://github.com/StevenBlack/hosts#sources-of-hosts-data-unified-in-this-variant).

## ⚖️ Licença

- **Código** (`gerar_lista.py` e o workflow): [MIT](LICENSE).
- **Lista gerada** (`minha_lista.txt`): é uma obra derivada das fontes acima e segue as licenças delas. Ao redistribuí-la, mantenha a atribuição ao AdAway (CC BY 3.0) e ao StevenBlack/hosts (MIT).

## 🤝 Contribuição

Encontrou um site que não deveria estar bloqueado? Abra uma **Issue**. Como a lista vem das fontes acima, falsos positivos também podem ser reportados diretamente a elas.
