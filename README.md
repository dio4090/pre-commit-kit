# pre-commit-kit

Hooks de commit que pegam o erro barato antes que ele custe um ciclo de CI — e que
impedem segredo e atribuição de IA de entrarem no histórico.

São quatro arquivos de configuração por stack, um hook global e um instalador. O que
tem de menos óbvio aqui não são os hooks em si: é **fazer o `pre-commit` conviver com
um hook global**, que por padrão é uma coisa que não acontece. Essa parte está
explicada em [As quatro camadas](#as-quatro-camadas).

## Instalação

Precisa de `git` e [`pre-commit`](https://pre-commit.com/#install). O `gitleaks` o
próprio `pre-commit` baixa na primeira execução.

```bash
git clone https://github.com/dio4090/pre-commit-kit.git
cd pre-commit-kit

./install.sh ~/meu-projeto          # um repositório
./install.sh ~/proj-a ~/proj-b      # vários de uma vez
./install.sh                        # o repositório atual
```

A stack é detectada pelos arquivos na raiz (`pom.xml` → java, `pyproject.toml` →
python, `package.json` → node, nenhum → base). Para forçar:

```bash
./install.sh --stack python ~/meu-projeto
```

**Um `.pre-commit-config.yaml` que já exista é preservado**, nunca sobrescrito — o
instalador só cuida dos hooks nesse caso. Para adotar o daqui, apague o seu antes.

## O que cada hook faz

Comum a todas as stacks:

| hook | o que pega |
|---|---|
| `trailing-whitespace`, `end-of-file-fixer`, `mixed-line-ending` | ruído de diff |
| `check-yaml`, `check-json` | arquivo que não parseia, antes do CI descobrir |
| `check-merge-conflict` | `<<<<<<<` commitado |
| `check-added-large-files` | binário acima de 500 KB |
| `detect-private-key` | chave privada em arquivo |
| `no-commit-to-branch` | commit direto em branch protegida |
| `gitleaks` | token, senha, credencial no diff |
| `sem-coautoria` | `Co-Authored-By:` na mensagem |

Por stack:

- **python** — `ruff-check --fix` e depois `ruff-format`. A ordem importa: lint com
  `--fix` antes do formatador, senão os dois brigam pelo mesmo arquivo.
- **node** — `oxlint` nos arquivos alterados, via `npx --no-install` (usa o do
  projeto; não instala nada por conta).
- **java** — nada além do comum. Checkstyle ficou de fora de propósito: passa de 5
  segundos e reprova pouco. Ele rende mais no CI do que no commit.

### Ajuste antes de usar

`no-commit-to-branch` vem com `main`, `dsv`, `hmg` e `prd`. Troque pelos nomes do
seu fluxo:

```yaml
- id: no-commit-to-branch
  args: [--branch, main, --branch, develop]
```

## Escapatórias

```bash
SKIP=ruff-format git commit ...    # pula um hook, mantém o resto
```

**Nunca use `--no-verify`.** Ele desliga tudo de uma vez, inclusive o `gitleaks` — e
segredo que entra no histórico só sai reescrevendo histórico, o que numa branch
compartilhada normalmente está fora de questão. Se um hook está atrapalhando,
`SKIP=` resolve sem abrir a porteira inteira.

## As quatro camadas

O `prepare-commit-msg` em `hooks/` remove atribuição de IA da mensagem de commit
(o trailer `Co-Authored-By:` de Claude/Anthropic e a linha `Generated with Claude
Code`). Ele é instalado **globalmente**, via `core.hooksPath`, para valer em
qualquer repositório da máquina.

E aí mora o problema: **o `pre-commit` se recusa a instalar quando `core.hooksPath`
está definido.**

```
Cowardly refusing to install hooks with `core.hooksPath` set.
```

A verificação está em `pre_commit/commands/install_uninstall.py`, e é deliberada —
com `core.hooksPath` apontando para fora, os hooks que ele escrevesse em
`.git/hooks/` nunca rodariam. Instalar o `pre-commit` do jeito ingênuo, portanto,
exige desativar o hook global. As duas proteções se excluem, e é isso que o
instalador resolve:

1. **Cortar na origem.** Com Claude Code, `.claude/settings.json` com
   `includeCoAuthoredBy: false` — a linha nem chega a ser escrita.
2. **Instalar com a config global neutralizada.** `GIT_CONFIG_GLOBAL=/dev/null
   pre-commit install` passa pela recusa sem desligar o `core.hooksPath` global
   para todos os outros repositórios da máquina.
3. **`core.hooksPath` local apontando para `.git/hooks`.** Sem isto o Git
   procuraria os hooks só em `~/.git-hooks` e os recém-instalados nunca rodariam.
   A config local vence a global.
4. **Copiar o `prepare-commit-msg` global para `.git/hooks/`.** O passo 3 tirou
   aquele repositório do alcance do hook global; a cópia o traz de volta. O hook
   tem guarda de recursão própria, então a cópia convive com o original.

Nenhuma das quatro é opcional. Tirar a 3 e os hooks do `pre-commit` viram
decoração; tirar a 4 e a remoção de atribuição some naquele repositório.

### Duas armadilhas que custam caro

**`--git-path` causa recursão infinita.** Para encadear um hook local, o hook global
precisa descobrir `.git/hooks/prepare-commit-msg`. `git rev-parse --git-path hooks`
parece o caminho certo, mas ele **respeita `core.hooksPath`** e devolve o próprio
hook global — que chama a si mesmo, para sempre. Use `--git-dir` e monte o caminho:

```sh
GITDIR="$(git rev-parse --git-dir)"
LOCAL="$GITDIR/hooks/prepare-commit-msg"
```

**Sem o bit de execução, o Git ignora o hook em silêncio.** Nenhum aviso, nenhum
erro: o hook simplesmente não roda e você descobre semanas depois. Daí o `chmod +x`
explícito no instalador.

## Conferindo que ficou de pé

Num repositório qualquer, numa branch descartável:

```bash
git checkout -b teste-hooks

# 1. co-autoria humana: o commit deve ser RECUSADO
printf 'test: hooks\n\nCo-Authored-By: Alguem <noreply@exemplo.com>\n' > /tmp/m
git commit --allow-empty -F /tmp/m

# 2. atribuição de IA: o commit PASSA e a linha some sozinha
printf 'test: hooks\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > /tmp/m
git commit --allow-empty -F /tmp/m
git log -1 --format='%B'        # a linha não deve aparecer

# 3. branch protegida: o commit deve ser RECUSADO
git checkout main
git commit --allow-empty -m 'test: branch protegida'
```

A diferença entre 1 e 2 é de propósito: **co-autoria humana legítima é preservada**,
e o que o `prepare-commit-msg` remove é só a atribuição de IA. O hook `sem-coautoria`
é a rede de baixo, para o caso de a remoção não ter acontecido.

Depois, `git checkout - && git branch -D teste-hooks`.

## Manutenção

Os `rev:` são fixados de propósito — config de hook sem versão fixa quebra sozinha
num dia qualquer. Para atualizar:

```bash
pre-commit autoupdate
```

Rodar em tudo, sem esperar o próximo commit:

```bash
pre-commit run --all-files
```

## Licença

MIT.
