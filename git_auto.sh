#!/usr/bin/env bash
set -uo pipefail

# Texto que muestra el prompt (lo actualiza PROMPT_COMMAND).
GIT_AUTO_PS1=""

if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'
  C_NEGRITA=$'\e[1m'
  C_CIAN=$'\e[36m'
  C_VERDE=$'\e[32m'
  C_AMARILLO=$'\e[33m'
  C_ROJO=$'\e[31m'
else
  C_RESET=""
  C_NEGRITA=""
  C_CIAN=""
  C_VERDE=""
  C_AMARILLO=""
  C_ROJO=""
fi

info() { printf '%s%s%s\n' "$C_CIAN" "$*" "$C_RESET"; }
ok() { printf '%s%s%s\n' "$C_VERDE" "$*" "$C_RESET"; }
warn() { printf '%s%s%s\n' "$C_AMARILLO" "$*" "$C_RESET" >&2; }
error() { printf '%s%s%s\n' "$C_ROJO" "$*" "$C_RESET" >&2; }

es_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

requerir_repo() {
  if ! es_repo; then
    error "No es un repositorio git. Use: $(basename "$0") --init"
    exit 1
  fi
}

rama_actual() {
  git symbolic-ref --short -q HEAD 2>/dev/null || git rev-parse --short HEAD 2>/dev/null || echo "(sin rama)"
}

cantidad_cambios() {
  git status --porcelain 2>/dev/null | wc -l | tr -d ' '
}

mostrar_ayuda() {
  local nombre
  nombre="$(basename "$0")"
  cat <<AYUDA
${C_NEGRITA}Uso:${C_RESET} ${nombre} [opción] [argumentos]

${C_NEGRITA}Opciones:${C_RESET}
  (sin opciones)            Muestra un resumen del estado del repositorio.
  -h, --help                Muestra esta ayuda.
  --init                    Inicializa un repositorio git (rama main) si no existe.
  --commit [mensaje]        Añade todos los cambios y hace commit con el mensaje.
                            Si no se indica mensaje, usa la fecha y hora actual
                            (formato %Y-%m-%d %H:%M:%S).
  --pull                    Trae modificaciones del servidor remoto.
  --push                    Envía modificaciones al servidor remoto.
  --branch                  Muestra las ramas existentes y señala la actual.
  --branch <rama>           Cambia a la rama indicada.
  --newbranch <rama>        Crea una nueva rama y cambia a ella.

${C_NEGRITA}Prompt con rama y cambios:${C_RESET}
  El script no puede cambiar el prompt de la shell padre si se ejecuta.
  Para activarlo en la sesión actual use:
    source ${nombre}

AYUDA
}

resumen() {
  requerir_repo

  local upstream="" adelante=0 atras=0 staged modificados sin_seguimiento ultimo

  info "Repositorio: $(git rev-parse --show-toplevel)"
  info "Rama actual: $(rama_actual)"

  if upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    read -r atras adelante < <(git rev-list --left-right --count "${upstream}...HEAD")
    info "Remoto (upstream): ${upstream} (adelante: ${adelante}, atrás: ${atras})"
  else
    info "Remoto (upstream): no configurado"
  fi

  staged=$(git diff --cached --name-only | wc -l | tr -d ' ')
  modificados=$(git diff --name-only | wc -l | tr -d ' ')
  sin_seguimiento=$(git ls-files --others --exclude-standard | wc -l | tr -d ' ')

  info "Cambios: $(cantidad_cambios) (preparados: ${staged}, modificados: ${modificados}, sin seguimiento: ${sin_seguimiento})"

  if ultimo=$(git log -1 --format='%h %s (%cr)' 2>/dev/null); then
    info "Último commit: ${ultimo}"
  else
    info "Último commit: ninguno todavía"
  fi
}

inicializar() {
  if es_repo; then
    ok "El directorio ya es un repositorio git."
    return 0
  fi
  git init -q && git symbolic-ref HEAD refs/heads/main
  ok "Repositorio inicializado con la rama main."
}

commit() {
  requerir_repo

  local mensaje="$*"
  if [[ -z "${mensaje//[[:space:]]/}" ]]; then
    mensaje="$(date '+%Y-%m-%d %H:%M:%S')"
  fi

  git add -A
  if git diff --cached --quiet; then
    warn "No hay cambios para hacer commit."
    return 0
  fi

  git commit -m "$mensaje" && ok "Commit realizado: ${mensaje}"
}

pull() {
  requerir_repo
  git pull
}

push() {
  requerir_repo

  if [[ -z "$(git remote 2>/dev/null)" ]]; then
    error "No hay ningún remoto configurado (git remote add origin <url>)."
    return 1
  fi

  if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    git push
  else
    git push -u origin "$(rama_actual)"
  fi
}

mostrar_rama() {
  requerir_repo
  local actual marks linea
  actual="$(rama_actual)"
  info "Rama actual: ${actual}"
  info "Ramas:"
  # Muestra todas las ramas locales marcando la actual con '*' y en verde.
  while IFS=$'\t' read -r marks linea; do
    if [[ "$marks" == "*" ]]; then
      printf '  %s* %s%s\n' "$C_VERDE" "$linea" "$C_RESET"
    else
      printf '    %s\n' "$linea"
    fi
  done < <(git branch --format='%(HEAD)%09%(refname:short)' 2>/dev/null)
}

cambiar_rama() {
  requerir_repo
  if ! git show-ref --verify --quiet "refs/heads/$1"; then
    error "La rama '$1' no existe. Use: --newbranch $1"
    return 1
  fi
  git switch "$1"
}

nueva_rama() {
  requerir_repo
  if [[ -z "${1:-}" ]]; then
    error "Indique el nombre de la nueva rama."
    return 1
  fi
  git switch -c "$1"
}

# Prompt: muestra [rama] (cambios sin commit) en cada orden.
actualizar_prompt() {
  if es_repo; then
    GIT_AUTO_PS1="[$(rama_actual)] ($(cantidad_cambios)) "
  else
    GIT_AUTO_PS1=""
  fi
}

activar_prompt() {
  PROMPT_COMMAND="actualizar_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
  PS1='\u@\h:\w ${GIT_AUTO_PS1}\$ '
  actualizar_prompt
  ok "Prompt de git_auto activado en esta sesión."
}

# Si se carga con 'source', solo activa el prompt.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  activar_prompt
  return 0
fi

case "${1:-}" in
  "")
    resumen
    echo
    info "Para ver rama y cambios en el prompt ejecute: source $(basename "$0")"
    ;;
  -h|--help) mostrar_ayuda ;;
  --init) inicializar ;;
  --commit) shift; commit "$@" ;;
  --pull) pull ;;
  --push) push ;;
  --branch)
    shift
    if [[ $# -eq 0 ]]; then
      mostrar_rama
    else
      cambiar_rama "$1"
    fi
    ;;
  --newbranch) shift; nueva_rama "${1:-}" ;;
  *)
    error "Opción no válida: $1"
    mostrar_ayuda
    exit 1
    ;;
esac

