#!/usr/bin/env bash
# Instala os hooks de commit num ou mais repositorios.
#
#   ./install.sh                    no repositorio atual
#   ./install.sh ~/proj-a ~/proj-b  nos repositorios indicados
#   ./install.sh --global           so o hook global de atribuicao de IA
#   ./install.sh --stack python .   forca a stack, em vez de detectar
#
# A PARTE DELICADA E A ORDEM. Leia o README antes de mexer: o pre-commit se recusa
# a instalar quando core.hooksPath esta definido, e e justamente o core.hooksPath
# global que mantem o hook de atribuicao de IA de pe. As quatro camadas abaixo
# existem para as duas coisas conviverem -- nenhuma delas e opcional.

set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_GLOBAL="$HOME/.git-hooks/prepare-commit-msg"

verde()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
amarelo() { printf '  \033[33m!\033[0m %s\n' "$*"; }
vermelho(){ printf '  \033[31m✗\033[0m %s\n' "$*"; }
titulo()  { printf '\n\033[1m%s\033[0m\n' "$*"; }

STACK=""
SO_GLOBAL=0
ALVOS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --global) SO_GLOBAL=1 ;;
    --stack)  STACK="${2:?--stack exige um valor}"; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*) vermelho "opcao desconhecida: $1"; exit 1 ;;
    *)  ALVOS+=("$1") ;;
  esac
  shift
done

# ------------------------------------------------- hook global (camada externa)

instala_global() {
  titulo "Hook global"
  mkdir -p "$(dirname "$HOOK_GLOBAL")"
  cp "$RAIZ/hooks/prepare-commit-msg" "$HOOK_GLOBAL"
  chmod +x "$HOOK_GLOBAL"
  git config --global core.hooksPath "$(dirname "$HOOK_GLOBAL")"
  verde "$HOOK_GLOBAL instalado e ativo via core.hooksPath global"
}

# ------------------------------------------------- deteccao de stack

detecta_stack() {
  local dir="$1"
  if   [ -f "$dir/pom.xml" ] || [ -f "$dir/build.gradle" ] || [ -f "$dir/build.gradle.kts" ]; then echo java
  elif [ -f "$dir/pyproject.toml" ] || [ -f "$dir/requirements.txt" ] || [ -f "$dir/setup.py" ]; then echo python
  elif [ -f "$dir/package.json" ]; then echo node
  else echo base
  fi
}

escreve_config() {
  local dir="$1" stack="$2" arquivo="$dir/.pre-commit-config.yaml"
  if [ -f "$arquivo" ]; then
    amarelo ".pre-commit-config.yaml ja existe; preservado"
    return 0
  fi
  cp "$RAIZ/configs/$stack.yaml" "$arquivo"
  verde ".pre-commit-config.yaml criado ($stack)"
}

# ------------------------------------------------- as quatro camadas

instala_repo() {
  local dir="$1"
  dir="$(cd "$dir" && pwd)"
  if [ ! -d "$dir/.git" ]; then
    vermelho "$dir nao e um repositorio git"
    return 1
  fi
  printf '\n  \033[1m%s\033[0m\n' "$dir"

  local stack="${STACK:-$(detecta_stack "$dir")}"
  escreve_config "$dir" "$stack"

  # Camada 2: a recusa do pre-commit olha `git config core.hooksPath`, que resolve a
  # config global. Neutralizar a global so durante a instalacao e o unico jeito de
  # passar sem desativar o hook de co-autoria para todos os outros repositorios.
  git -C "$dir" config --local --unset-all core.hooksPath 2>/dev/null || true
  if (cd "$dir" && GIT_CONFIG_GLOBAL=/dev/null pre-commit install --install-hooks \
        -t pre-commit -t commit-msg >/dev/null 2>&1); then
    verde "pre-commit instalado"
  else
    vermelho "falha ao instalar o pre-commit"
    return 1
  fi

  # Camada 3: sem isto o Git procuraria os hooks so em ~/.git-hooks e os recem
  # instalados nunca rodariam. A config local vence a global.
  git -C "$dir" config --local core.hooksPath .git/hooks

  # Camada 4: o hook global tem guarda de recursao, entao a copia convive com o
  # original. Sem o bit de execucao o Git ignora o hook em silencio.
  if [ -f "$HOOK_GLOBAL" ]; then
    cp "$HOOK_GLOBAL" "$dir/.git/hooks/prepare-commit-msg"
    chmod +x "$dir/.git/hooks/prepare-commit-msg"
    verde "prepare-commit-msg (remocao de atribuicao de IA) preservado"
  else
    amarelo "$HOOK_GLOBAL nao encontrado -- rode com --global antes"
  fi
}

# ------------------------------------------------- execucao

for c in git pre-commit; do
  command -v "$c" >/dev/null 2>&1 || { vermelho "$c ausente (necessario)"; exit 1; }
done
command -v gitleaks >/dev/null 2>&1 || amarelo "gitleaks ausente: o pre-commit baixa o proprio na primeira execucao"

if [ "$SO_GLOBAL" = "1" ]; then
  instala_global
  exit 0
fi

[ -f "$HOOK_GLOBAL" ] || instala_global

[ ${#ALVOS[@]} -gt 0 ] || ALVOS=(".")

titulo "Hooks por repositorio"
FALHOU=0
for d in "${ALVOS[@]}"; do
  instala_repo "$d" || FALHOU=1
done

titulo "Como conferir que ficou de pe"
cat <<'EOF'
  Num repositorio qualquer, numa branch descartavel:

    git checkout -b teste-hooks
    printf 'test: hooks\n\nCo-Authored-By: Alguem <noreply@exemplo.com>\n' > /tmp/m
    git commit --allow-empty -F /tmp/m && git log -1 --format='%B'

  O hook de commit-msg deve recusar o commit. Trocando o autor por um
  com "claude" ou "anthropic" no endereco, o commit passa e a linha some
  sozinha da mensagem gravada -- e o prepare-commit-msg agindo.
EOF
printf '\n'
exit $FALHOU
