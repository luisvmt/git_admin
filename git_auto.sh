#!/usr/bin/env bash
set -uo pipefail

# ============================================================
# git_auto.sh — utilidad para administrar repositorios git
# ============================================================

GIT_AUTO_PS1=""

# ---------- Colores ----------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'
  C_NEGRITA=$'\e[1m'
  C_CIAN=$'\e[36m'
  C_VERDE=$'\e[32m'
  C_AMARILLO=$'\e[33m'
  C_ROJO=$'\e[31m'
else
  C_RESET=""; C_NEGRITA=""; C_CIAN=""; C_VERDE=""; C_AMARILLO=""; C_ROJO=""
fi

info()  { printf '%s%s%s\n' "$C_CIAN"     "$*" "$C_RESET"; }
ok()    { printf '%s%s%s\n' "$C_VERDE"    "$*" "$C_RESET"; }
warn()  { printf '%s%s%s\n' "$C_AMARILLO" "$*" "$C_RESET" >&2; }
error() { printf '%s%s%s\n' "$C_ROJO"     "$*" "$C_RESET" >&2; }

# ---------- Helpers git ----------
es_repo() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }

requerir_repo() {
  if ! es_repo; then
    error "No es un repositorio git. Use: $(basename "$0") --init"
    exit 1
  fi
}

# git switch con fallback a git checkout (para git < 2.23)
cambiar_a() {
  if git switch "$@" 2>/dev/null; then return 0; fi
  if [[ "${1:-}" == "-c" ]]; then shift; git checkout -b "$@"; else git checkout "$@"; fi
}

rama_actual() {
  git symbolic-ref --short -q HEAD 2>/dev/null \
    || git rev-parse --short HEAD 2>/dev/null \
    || echo "(sin rama)"
}

cantidad_cambios() { git status --porcelain 2>/dev/null | wc -l | tr -d ' '; }

remoto_existe() { git remote get-url "$1" >/dev/null 2>&1; }
tiene_upstream() { git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; }

# ---------- Ayuda ----------
mostrar_ayuda() {
  local nombre; nombre="$(basename "$0")"
  cat <<AYUDA
${C_NEGRITA}Uso:${C_RESET} ${nombre} [opción] [argumentos]

${C_NEGRITA}Estado y navegación:${C_RESET}
  (sin opciones)            Muestra un resumen del estado del repositorio.
  -h, --help                Muestra esta ayuda.
  --status                  Muestra el estado completo (git status).
  --log [n]                 Muestra los últimos n commits (por defecto 10).
  --branch                  Muestra las ramas existentes y señala la actual.
  --branch <rama>           Cambia a la rama indicada.
  --newbranch <rama>        Crea una nueva rama y cambia a ella.

${C_NEGRITA}Repositorio remoto:${C_RESET}
  --remote                         Muestra los remotos configurados.
  --remote add <url> [nombre]      Añade un remoto (nombre por defecto: origin).
  --remote set-url <url> [nombre]  Cambia la URL del remoto indicado.
  --remote remove [nombre]         Elimina el remoto indicado.
  --pull                           Trae modificaciones del servidor remoto.
  --push                           Envía modificaciones al servidor remoto.

${C_NEGRITA}Commits:${C_RESET}
  --init                    Inicializa un repositorio git (rama main) si no existe.
  --commit [mensaje]        Añade todos los cambios y hace commit con el mensaje.
                            Sin mensaje: usa la fecha y hora actual
                            (formato %Y-%m-%d %H:%M:%S).
  --amend [mensaje]         Corrige el último commit (mismo criterio de mensaje).
  --uncommit                Deshace el último commit conservando los cambios
                            en staging (git reset --soft HEAD~1).

${C_NEGRITA}Prompt con rama y cambios:${C_RESET}
  El script no puede cambiar el prompt de la shell padre si se ejecuta.
  Para activarlo en la sesión actual use:
    source ${nombre}

${C_NEGRITA}Ejemplos:${C_RESET}
  ${nombre} --remote add git@github.com:usuario/repo.git
  ${nombre} --remote add https://github.com/usuario/repo.git upstream
  ${nombre} --remote                    # ver remotos
  ${nombre} --commit "feat: nueva función"
  ${nombre} --commit                    # mensaje = fecha/hora
  ${nombre} --log 5
  ${nombre} --amend "mensaje corregido"
  ${nombre} --uncommit
AYUDA
}

# ---------- Resumen ----------
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

# ---------- Init ----------
inicializar() {
  if es_repo; then ok "El directorio ya es un repositorio git."; return 0; fi
  git init -q && git symbolic-ref HEAD refs/heads/main
  ok "Repositorio inicializado con la rama main."
}

# ---------- Commit / Amend / Uncommit ----------
_commit_mensaje() {
  local mensaje="$*"
  if [[ -z "${mensaje//[[:space:]]/}" ]]; then
    mensaje="$(date '+%Y-%m-%d %H:%M:%S')"
  fi
  printf '%s' "$mensaje"
}

commit() {
  requerir_repo
  local mensaje; mensaje="$(_commit_mensaje "$@")"

  if ! git add -A; then
    error "Falló 'git add -A'."
    return 1
  fi

  if git diff --cached --quiet; then
    warn "No hay cambios para hacer commit."
    return 0
  fi

  git commit -m "$mensaje" && ok "Commit realizado: ${mensaje}"
}

amend() {
  requerir_repo
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    error "No hay commits para corregir."; return 1
  fi
  local mensaje; mensaje="$(_commit_mensaje "$@")"
  git add -A
  git commit --amend -m "$mensaje" && ok "Commit corregido: ${mensaje}"
}

uncommit() {
  requerir_repo
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    error "No hay commits para deshacer."; return 1
  fi
  git reset --soft HEAD~1 && ok "Último commit deshecho (cambios conservados en staging)."
}

# ---------- Pull / Push ----------
pull() { requerir_repo; git pull; }

push() {
  requerir_repo
  if [[ -z "$(git remote 2>/dev/null)" ]]; then
    error "No hay ningún remoto configurado. Use: $(basename "$0") --remote add <url>"
    return 1
  fi
  if tiene_upstream; then git push; else git push -u origin "$(rama_actual)"; fi
}

# ---------- Ramas ----------
mostrar_rama() {
  requerir_repo
  local actual marks linea
  actual="$(rama_actual)"
  info "Rama actual: ${actual}"
  info "Ramas:"
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
  if [[ -z "${1:-}" ]]; then error "Indique el nombre de la rama."; return 1; fi
  if ! git show-ref --verify --quiet "refs/heads/$1"; then
    error "La rama '$1' no existe. Use: --newbranch $1"; return 1
  fi
  cambiar_a "$1"
}

nueva_rama() {
  requerir_repo
  if [[ -z "${1:-}" ]]; then error "Indique el nombre de la nueva rama."; return 1; fi
  cambiar_a -c "$1"
}

# ---------- Remotos (NUEVO) ----------
mostrar_remoto() {
  requerir_repo
  local remotos
  remotos="$(git remote -v 2>/dev/null)"
  if [[ -z "$remotos" ]]; then
    warn "No hay remotos configurados."
    info "Añada uno con: $(basename "$0") --remote add <url> [nombre]"
    return 1
  fi
  info "Remotos configurados:"
  while IFS= read -r linea; do printf '  %s\n' "$linea"; done <<< "$remotos"
}

agregar_remoto() {
  requerir_repo
  local url="${1:-}" nombre="${2:-origin}"
  if [[ -z "$url" ]]; then
    error "Debe indicar la URL del remoto."
    error "Uso: $(basename "$0") --remote add <url> [nombre]"
    return 1
  fi
  if remoto_existe "$nombre"; then
    error "El remoto '$nombre' ya existe. Use: --remote set-url <url> [$nombre]"
    return 1
  fi
  git remote add "$nombre" "$url" && ok "Remoto '$nombre' añadido: $url"
}

cambiar_url_remoto() {
  requerir_repo
  local url="${1:-}" nombre="${2:-origin}"
  if [[ -z "$url" ]]; then
    error "Debe indicar la nueva URL."
    error "Uso: $(basename "$0") --remote set-url <url> [nombre]"
    return 1
  fi
  if ! remoto_existe "$nombre"; then
    error "El remoto '$nombre' no existe. Use: --remote add <url> [$nombre]"
    return 1
  fi
  git remote set-url "$nombre" "$url" && ok "URL del remoto '$nombre' actualizada: $url"
}

eliminar_remoto() {
  requerir_repo
  local nombre="${1:-origin}"
  if ! remoto_existe "$nombre"; then
    error "El remoto '$nombre' no existe."; return 1
  fi
  git remote remove "$nombre" && ok "Remoto '$nombre' eliminado."
}

comando_remoto() {
  local sub="${1:-}"
  case "$sub" in
    "")        mostrar_remoto ;;
    add)       shift; agregar_remoto "$@" ;;
    set-url)   shift; cambiar_url_remoto "$@" ;;
    remove|rm) shift; eliminar_remoto "$@" ;;
    *)
      error "Subcomando no válido: $sub"
      error "Uso: --remote [ver] | add <url> [nombre] | set-url <url> [nombre] | remove [nombre]"
      return 1
      ;;
  esac
}

# ---------- Log / Status ----------
ver_log() {
  requerir_repo
  local n="${1:-10}"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    error "El argumento de --log debe ser un número."; return 1
  fi
  git log --oneline --decorate --graph -n "$n"
}

status_completo() { requerir_repo; git status; }

# ---------- Prompt ----------
actualizar_prompt() {
  if es_repo; then
    GIT_AUTO_PS1="[$(rama_actual)] ($(cantidad_cambios)) "
  else
    GIT_AUTO_PS1=""
  fi
}

_prompt_command_ya_incluye_hook() {
  if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    local cmd
    for cmd in "${PROMPT_COMMAND[@]}"; do
      [[ "$cmd" == "actualizar_prompt" ]] && return 0
    done
    return 1
  else
    [[ "${PROMPT_COMMAND:-}" == *"actualizar_prompt"* ]]
  fi
}

activar_prompt() {
  actualizar_prompt
  if ! _prompt_command_ya_incluye_hook; then
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
      PROMPT_COMMAND=(actualizar_prompt "${PROMPT_COMMAND[@]}")
    else
      PROMPT_COMMAND="actualizar_prompt${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
    fi
  fi
  PS1='\u@\h:\w ${GIT_AUTO_PS1}\$ '
  ok "Prompt de git_auto activado en esta sesión."
}

# ============================================================
# Carga con 'source': solo activa el prompt.
# ============================================================
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  activar_prompt
  return 0
fi

# ============================================================
# Dispatch
# ============================================================
case "${1:-}" in
  "")
    resumen
    echo
    info "Para ver rama y cambios en el prompt ejecute: source $(basename "$0")"
    ;;
  -h|--help)   mostrar_ayuda ;;
  --init)      inicializar ;;
  --commit)    shift; commit "$@" ;;
  --amend)     shift; amend "$@" ;;
  --uncommit)  uncommit ;;
  --pull)      pull ;;
  --push)      push ;;
  --branch)
    shift
    if [[ $# -eq 0 ]]; then mostrar_rama; else cambiar_rama "$1"; fi
    ;;
  --newbranch) shift; nueva_rama "${1:-}" ;;
  --remote)    shift; comando_remoto "$@" ;;
  --log)       shift; ver_log "${1:-10}" ;;
  --status)    status_completo ;;
  *)
    error "Opción no válida: $1"
    mostrar_ayuda
    exit 1
    ;;
esac