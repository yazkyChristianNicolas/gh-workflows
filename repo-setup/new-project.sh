#!/usr/bin/env bash
# Crea el repo de una app nueva con el flujo build-once / promote ya armado:
#
#   1. Crea el repo en GitHub (si no existe) y lo clona.
#   2. Escribe .github/workflows/development.yml y production.yml (callers de este repo) y los
#      pushea a `main`.
#   3. Genera configs/<repo>.json y corre setup-repo.sh: branch `development`, rulesets,
#      environments y secrets (los valores salen de ~/.config/gh-workflows/secrets.env).
#
# Uso:
#   ./new-project.sh <owner/repo> --domain <dominio> --sub <app|api|…> \
#       --compose-service <servicio> --tag-variable <VAR_TAG> \
#       [--stack node|none] [--target <stage>] [--health-path /] [--public] [--dir <carpeta>] [--dry-run]
#
#   --sub              app -> dev-app.<dominio> (development) y app.<dominio> (production).
#   --compose-service  nombre del servicio en el compose del servidor.
#   --tag-variable     variable <APP>_TAG que el deploy escribe en el .env del servidor.
#   --stack node       agrega un job `checks` (npm ci, lint, typecheck, test:run) y lo exige en
#                      los PR; `none` (por defecto) solo construye y despliega la imagen.
#   --target           stage del Dockerfile a construir (ej. runtime).
#   --dry-run          muestra los archivos y la config sin crear ni pushear nada.
#
# Idempotente: si el repo o la carpeta ya existen los reusa, y setup-repo.sh converge a la
# config. NO genera el Dockerfile ni el compose/Caddy del servidor (ver el playbook, Fase 5).
# Los commits salen con tu usuario de git, sin trailers.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SECRETS="${GH_SETUP_SECRETS:-$HOME/.config/gh-workflows/secrets.env}"
SECRET_NAMES=(DEPLOY_HOST DEPLOY_USER DEPLOY_SSH_KEY DEPLOY_KNOWN_HOSTS SERVICE_REPO_TOKEN)

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
[ "$#" -ge 1 ] || usage
REPO="$1"; shift
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "Repo inválido: $REPO (owner/repo)" >&2; exit 1; }
NAME="${REPO#*/}"

DOMAIN=""; SUB=""; SERVICE=""; TAGVAR=""; STACK=none; TARGET=""; HEALTH=/; VISIBILITY=--private
DIR="$PWD/$NAME"; DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --sub) SUB="$2"; shift 2 ;;
    --compose-service) SERVICE="$2"; shift 2 ;;
    --tag-variable) TAGVAR="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --health-path) HEALTH="$2"; shift 2 ;;
    --public) VISIBILITY=--public; shift ;;
    --dir) DIR="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) echo "Opción desconocida: $1" >&2; usage ;;
  esac
done
for v in DOMAIN SUB SERVICE TAGVAR; do [ -n "${!v}" ] || { echo "Falta --$(echo "$v" | tr 'A-Z_' 'a-z-')" >&2; usage; }; done
[[ "$STACK" = node || "$STACK" = none ]] || { echo "--stack: node o none" >&2; exit 1; }
[[ "$TAGVAR" =~ ^[A-Z][A-Z0-9_]*_TAG$ ]] || { echo "--tag-variable debe verse como WEB_APP_TAG" >&2; exit 1; }

command -v jq >/dev/null || { echo "Falta jq" >&2; exit 1; }
if [ "$DRY" = 0 ]; then
  command -v gh >/dev/null || { echo "Falta gh" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "gh sin sesión: gh auth login" >&2; exit 1; }
  # Antes de crear nada: que estén todos los secrets que va a pedir setup-repo.sh.
  for s in "${SECRET_NAMES[@]}"; do
    grep -qE "^$s=" "$SECRETS" 2>/dev/null || { echo "Falta $s en $SECRETS (ver repo-setup/secrets.env.example)" >&2; exit 1; }
  done
fi

OWNER="${REPO%/*}"
OWNER_PREFIX="$OWNER"   # los workflows reusables viven en <owner>/gh-workflows

dev_workflow() {
  cat <<E
name: Development

# Verify en cada PR; en push a \`development\` construye la imagen una sola vez (tag
# \`tree-<árbol de git>\`) y la despliega en el environment \`development\`. Esa misma imagen es la
# que production.yml promueve al mergear a \`main\`.
# Build y deploy: $OWNER_PREFIX/gh-workflows (container-image.yml, ver su README).
on:
  pull_request:
  push:
    branches: [development]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
E
  if [ "$STACK" = node ]; then
    cat <<'E'
  checks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: actions/setup-node@v5
        with:
          node-version: 24
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npm run typecheck
      - run: npm run test:run

E
  fi
  local needs="" target=""
  [ "$STACK" = node ] && needs=$'\n    needs: [checks]'
  [ -n "$TARGET" ] && target=$'\n      target: '"$TARGET"
  cat <<E
  image:${needs}
    if: github.event_name != 'pull_request'
    uses: $OWNER_PREFIX/gh-workflows/.github/workflows/container-image.yml@main
    with:${target}
      push-image: true
      deploy: true
      environment: development
      compose-service: $SERVICE
      tag-variable: $TAGVAR
    secrets: inherit
E
}

prod_workflow() {
  cat <<E
name: Production

# Promoción: al mergear \`development\` a \`main\` no se buildea nada. Se busca la imagen que ya se
# construyó y probó en desarrollo para este mismo contenido (mismo árbol de git) y se despliega
# en el environment \`production\`. Si no existe, el contenido no pasó por \`development\` y la
# promoción falla.
on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  packages: write

jobs:
  promote:
    uses: $OWNER_PREFIX/gh-workflows/.github/workflows/promote-image.yml@main
    with:
      environment: production
      compose-service: $SERVICE
      tag-variable: $TAGVAR
    secrets: inherit
E
}

config() {
  jq -n --arg repo "$REPO" --arg stack "$STACK" --arg svc "$SERVICE" --arg sub "$SUB" \
        --arg domain "$DOMAIN" --arg health "$HEALTH" --argjson names "$(printf '%s\n' "${SECRET_NAMES[@]}" | jq -R . | jq -sc .)" '{
    repository: $repo,
    default_branch: "development",
    protected_branches: ["development", "main"],
    required_checks: (if $stack == "node" then ["checks"] else [] end),
    required_approvals: 0,
    environments: {
      development: { branch: "development", variables: {
        DEPLOY_ENABLED: "true", COMPOSE_DIR: "/opt/stack-dev",
        HEALTHCHECK_URL: "https://dev-\($sub).\($domain)\($health)" } },
      production: { branch: "main", reviewers: [], variables: {
        DEPLOY_ENABLED: "false", COMPOSE_DIR: "/opt/stack",
        HEALTHCHECK_URL: "https://\($sub).\($domain)\($health)" } }
    },
    secrets: $names
  }'
}

if [ "$DRY" = 1 ]; then
  echo "# [dry-run] $REPO ($VISIBILITY) -> $DIR"
  echo; echo "# .github/workflows/development.yml"; dev_workflow
  echo; echo "# .github/workflows/production.yml"; prod_workflow
  echo; echo "# repo-setup/configs/$NAME.json"; config
  exit 0
fi

step() { printf '\n== %s\n' "$*"; }

step "1. Repo $REPO"
if gh repo view "$REPO" >/dev/null 2>&1; then
  echo "ya existe"
else
  gh repo create "$REPO" "$VISIBILITY" >/dev/null
  echo "creado"
fi
if [ -d "$DIR/.git" ]; then
  echo "ya clonado en $DIR"
else
  gh repo clone "$REPO" "$DIR" >/dev/null 2>&1 || git clone -q "https://github.com/$REPO.git" "$DIR"
fi

step "2. Workflows en main"
cd "$DIR"
git checkout -q -B main 2>/dev/null || true
mkdir -p .github/workflows
dev_workflow > .github/workflows/development.yml
prod_workflow > .github/workflows/production.yml
git add .github/workflows/development.yml .github/workflows/production.yml
if git diff --cached --quiet; then
  echo "sin cambios"
else
  git commit -q -m "Pipelines de development y production"
  git push -q -u origin main
  echo "pusheado a main"
fi

step "3. Config y setup-repo.sh"
CONFIG="$HERE/configs/$NAME.json"
config > "$CONFIG"
echo "config en $CONFIG"
"$HERE/setup-repo.sh" "$CONFIG"

step "Listo"
echo "Falta: Dockerfile${TARGET:+ (stage $TARGET)} en $DIR; servicio $SERVICE en el compose del servidor;"
echo "bloque de dev-$SUB.$DOMAIN y $SUB.$DOMAIN en el Caddyfile; y el registro A (dns-records.sh)."
echo "Guardá $CONFIG en este repo (git add) para que sea la fuente de verdad."
