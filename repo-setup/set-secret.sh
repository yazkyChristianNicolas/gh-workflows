#!/usr/bin/env bash
# Carga (o rota) un secret: lo guarda en ~/.config/gh-workflows/secrets.env y lo sube a los repos
# de GitHub que lo declaran en su config (configs/*.json, campo "secrets").
#
#   ./set-secret.sh <NOMBRE> [--repo owner/repo]... [--verify owner/repo] [--no-verify]
#                            [--check] [--dry-run]
#
# El valor se pide sin eco (o se lee de stdin si no es una terminal); nunca se imprime ni queda
# en el historial ni en argumentos de procesos.
#
#   --repo      repos donde cargarlo. Por defecto, todos los configs que listan <NOMBRE>.
#   --verify    antes de guardar, prueba el token contra GET /repos/<owner/repo>/contents (lo que
#               hace el checkout del workflow). Para SERVICE_REPO_TOKEN el repo por defecto es
#               arca-invoicing-service. Si falla, no guarda nada. --no-verify lo saltea.
#   --check     no cambia nada: prueba el valor que ya está en secrets.env y dice si sirve y
#               cuándo vence (solo tokens fine-grained informan vencimiento).
#   --dry-run   muestra qué haría sin guardar ni subir nada (la verificación sí consulta GitHub).
#
# Resultado de la verificación (HTTP):
#   200  sirve: llega al repo con Contents: read.
#   401  token vencido, revocado o mal copiado.
#   403/404  el token es válido pero no tiene acceso al repo o le falta Contents: read.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SECRETS_FILE="${GH_SETUP_SECRETS:-$HOME/.config/gh-workflows/secrets.env}"

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 1; }
[ "$#" -ge 1 ] || usage
NAME="$1"; shift
[[ "$NAME" =~ ^[A-Z][A-Z0-9_]*$ ]] || { echo "Nombre inválido: $NAME (MAYUSCULAS_Y_GUIONES_BAJOS)" >&2; exit 1; }

REPOS=(); VERIFY=""; NO_VERIFY=0; CHECK=0; DRY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPOS+=("$2"); shift 2 ;;
    --verify) VERIFY="$2"; shift 2 ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --check) CHECK=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) echo "Opción desconocida: $1" >&2; usage ;;
  esac
done

for bin in curl jq; do command -v "$bin" >/dev/null || { echo "Falta $bin" >&2; exit 1; }; done

# Repo contra el que se prueba el token.
if [ -z "$VERIFY" ] && [ "$NAME" = SERVICE_REPO_TOKEN ]; then
  VERIFY="yazkyChristianNicolas/arca-invoicing-service"
fi
[ "$NO_VERIFY" = 0 ] || VERIFY=""
if [ "$CHECK" = 1 ] && [ -z "$VERIFY" ]; then
  echo "--check necesita un repo: pasá --verify owner/repo" >&2; exit 1
fi

# Repos por defecto: los configs que listan este secret.
if [ "${#REPOS[@]}" -eq 0 ]; then
  while IFS= read -r repo; do [ -n "$repo" ] && REPOS+=("$repo"); done < <(
    jq -r --arg n "$NAME" 'select(.secrets // [] | index($n)) | .repository' "$HERE"/configs/*.json)
fi

# Valor guardado en secrets.env (KEY=value o KEY=@archivo).
stored_value() {
  local line value
  line="$(grep -E "^${NAME}=" "$SECRETS_FILE" 2>/dev/null | tail -1 || true)"
  [ -n "$line" ] || { echo "$NAME no está en $SECRETS_FILE" >&2; return 1; }
  value="${line#*=}"
  value="${value%\"}"; value="${value#\"}"
  if [[ "$value" == @* ]]; then
    local path="${value#@}"; path="${path/#\~/$HOME}"
    cat "$path"
  else
    printf '%s' "$value"
  fi
}

# Prueba el token como lo hace el checkout del workflow. Imprime el resultado; devuelve 0 si sirve.
# El token viaja por stdin de curl (-K -), no en los argumentos.
verify_token() {
  local token="$1" repo="$2" headers status expiry
  headers="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -K - -D - -o /dev/null \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$repo/contents" | tr -d '\r')" || { echo "No pude consultar GitHub (red)." >&2; return 2; }
  status="$(printf '%s\n' "$headers" | awk 'toupper($1) ~ /^HTTP/ {s=$2} END {print s}')"
  expiry="$(printf '%s\n' "$headers" | awk -F': ' 'tolower($1)=="github-authentication-token-expiration" {print $2}')"
  echo "Verificación contra $repo: HTTP $status"
  if [ -n "$expiry" ]; then echo "Vence: $expiry"; else echo "Vencimiento: no informado (token sin vencimiento, classic o sin acceso)"; fi
  case "$status" in
    200) echo "Sirve: llega al repo con Contents: read."; return 0 ;;
    401) echo "No sirve: el token está vencido, revocado o mal copiado." >&2 ;;
    403|404) echo "No sirve: el token es válido pero no ve ese repo o le falta Contents: read (Repository access / Permissions)." >&2 ;;
    *) echo "Respuesta inesperada de GitHub." >&2 ;;
  esac
  return 1
}

if [ "$CHECK" = 1 ]; then
  token="$(stored_value)"
  verify_token "$token" "$VERIFY"
  exit $?
fi

if [ -t 0 ]; then
  read -r -s -p "Valor de $NAME: " VALUE; echo
else
  VALUE="$(cat)"
fi
VALUE="${VALUE%$'\r'}"
[ -n "$VALUE" ] || { echo "Valor vacío." >&2; exit 1; }
[[ "$VALUE" != *$'\n'* ]] || { echo "El valor tiene varias líneas: para eso usá NOMBRE=@archivo en secrets.env." >&2; exit 1; }

if [ -n "$VERIFY" ]; then
  verify_token "$VALUE" "$VERIFY" || { echo "No se guardó nada. Corregí el token y volvé a correr." >&2; exit 1; }
fi

if [ "$DRY" = 1 ]; then
  echo "[dry-run] guardaría $NAME en $SECRETS_FILE"
  for repo in ${REPOS[@]+"${REPOS[@]}"}; do echo "[dry-run] gh secret set $NAME -R $repo"; done
  [ "${#REPOS[@]}" -gt 0 ] || echo "[dry-run] ningún repo lista $NAME en configs/*.json"
  exit 0
fi

# secrets.env: reemplaza la línea de este secret sin tocar el resto (archivo nuevo, permisos 600).
mkdir -p "$(dirname "$SECRETS_FILE")"; touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"
TMP="$(mktemp "$SECRETS_FILE.XXXXXX")"; chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
grep -vE "^${NAME}=" "$SECRETS_FILE" > "$TMP" || true
printf '%s=%s\n' "$NAME" "$VALUE" >> "$TMP"
mv "$TMP" "$SECRETS_FILE"
echo "Guardado $NAME en $SECRETS_FILE"

if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "Ningún repo lista $NAME en configs/*.json: no se subió a GitHub (usá --repo owner/repo)."
else
  command -v gh >/dev/null || { echo "Falta gh" >&2; exit 1; }
  for repo in "${REPOS[@]}"; do
    printf '%s' "$VALUE" | gh secret set "$NAME" -R "$repo" > /dev/null
    echo "Subido a $repo"
  done
fi
unset VALUE
