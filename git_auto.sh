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

# ---------- Colores del prompt (configurables por variable de entorno) ----------
# Rama en verde negrita y número de cambios en amarillo.
C_RAMA_PROMPT="${C_RAMA_PROMPT-${C_NEGRITA}${C_VERDE}}"
C_CAMBIOS_PROMPT="${C_CAMBIOS_PROMPT-${C_AMARILLO}}"
# Reset para el prompt: se emite solo cuando hay colores activos.
C_PROMPT_RESET="${C_PROMPT_RESET-$'\e[0m'}"

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

upstream_actual() {
  git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null
}

# Nombre del remoto a partir del upstream (p. ej. "origin/main" -> "origin").
remoto_del_upstream() {
  local upstream="$1" remoto="${1%%/*}"
  [[ "$remoto" == "$upstream" ]] && remoto="origin"
  printf '%s' "$remoto"
}

# Actualiza las referencias del remoto del upstream. Devuelve 1 si falla.
actualizar_remoto() {
  local upstream="$1" remoto
  remoto="$(remoto_del_upstream "$upstream")"
  info "Actualizando referencias del remoto '${remoto}' (git fetch)..."
  git fetch "$remoto"
}

# Compara el upstream con HEAD y devuelve "atras adelante": cuántos commits
# hay solo en el remoto y cuántos solo en local.
contar_divergencia() {
  local upstream="$1" atras adelante
  read -r atras adelante < <(git rev-list --left-right --count "${upstream}...HEAD" 2>/dev/null)
  printf '%s %s' "${atras:-0}" "${adelante:-0}"
}

# Remoto principal: "origin" si existe; si no, el primero configurado.
remoto_principal() {
  local remotos
  remotos="$(git remote 2>/dev/null)"
  [[ -z "$remotos" ]] && return 1
  if grep -qx 'origin' <<< "$remotos"; then
    printf 'origin'
  else
    head -n 1 <<< "$remotos"
  fi
}

# Configura el upstream de la rama actual a partir de <remoto>/<rama> si esa
# rama existe en el remoto. Devuelve 1 si no se puede configurar.
configurar_upstream() {
  local remoto="$1" rama candidato
  rama="$(rama_actual)"
  candidato="${remoto}/${rama}"

  git show-ref --verify --quiet "refs/remotes/${candidato}" || return 1
  git branch --set-upstream-to="$candidato" "$rama" >/dev/null 2>&1 || return 1

  ok "Upstream configurado: ${candidato}"
}

# Asegura que la rama actual tenga upstream. Si no lo tiene, actualiza el
# remoto principal y lo vincula a <remoto>/<rama>.
asegurar_upstream() {
  local remoto

  if tiene_upstream; then
    return 0
  fi

  if [[ -z "$(git remote 2>/dev/null)" ]]; then
    error "No hay ningún remoto configurado. Use: $(basename "$0") --remote add <url>"
    return 1
  fi

  if ! remoto="$(remoto_principal)"; then
    error "No se pudo determinar el remoto principal."
    return 1
  fi

  info "Actualizando referencias del remoto '${remoto}' (git fetch)..."
  if ! git fetch "$remoto"; then
    error "No se pudo actualizar el remoto '${remoto}'."
    return 1
  fi

  if ! configurar_upstream "$remoto"; then
    error "La rama '$(rama_actual)' no tiene upstream y '${remoto}' no tiene esa rama."
    error "Publique la rama con: $(basename "$0") --push"
    return 1
  fi

  return 0
}

# ¿La referencia indicada y HEAD no comparten ningún ancestro?
sin_ancestro_comun() {
  ! git merge-base "$1" HEAD >/dev/null 2>&1
}

# ---------- Ayuda ----------
mostrar_ayuda() {
  local nombre; nombre="$(basename "$0")"
  cat <<AYUDA
${C_NEGRITA}Uso:${C_RESET} ${nombre} [opción] [argumentos]

${C_NEGRITA}Estado y navegación:${C_RESET}
  (sin opciones)            Muestra un resumen del estado del repositorio.
  --menu                    Menú interactivo con todas las opciones.
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
  --pull --rebase                  Si hay divergencia, reaplica los commits
                                   locales sobre los del remoto.
  --pull --merge                   Si hay divergencia, crea un commit de fusión.
  --push                           Envía modificaciones al servidor remoto.
                                   Si el remoto tiene commits nuevos, indica
                                   ejecutar --pull antes de enviar.

${C_NEGRITA}Commits:${C_RESET}
  --init                    Inicializa un repositorio git (rama main) y crea
                            los archivos de plantilla que falten.
  --commit [mensaje]        Añade todos los cambios y hace commit con el mensaje.
                            Sin mensaje: usa la fecha y hora actual
                            (formato %Y-%m-%d %H:%M:%S).
  --amend [mensaje]         Corrige el último commit (mismo criterio de mensaje).
  --uncommit                Deshace el último commit conservando los cambios
                            en staging (git reset --soft HEAD~1).

${C_NEGRITA}Diferencias (con delta --side-by-side):${C_RESET}
  --showdiff-local                  Muestra los cambios de todos los archivos
                                    modificados o nuevos contra el repositorio local.
  --showdiff-local <archivo>        Muestra los cambios de <archivo> contra el
                                    repositorio local.
  --showdiff-remote                 Muestra los cambios de todos los archivos
                                    modificados o nuevos contra el remoto (upstream).
  --showdiff-remote <archivo>       Muestra los cambios de <archivo> contra el remoto.

${C_NEGRITA}Prompt con rama y cambios:${C_RESET}
  El prompt muestra [rama] (cambios): la rama en verde negrita y el número
  de cambios sin commit en amarillo.
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
  ${nombre} --showdiff-local
  ${nombre} --showdiff-local README.md
  ${nombre} --showdiff-remote
  ${nombre} --showdiff-remote README.md
  ${nombre} --amend "mensaje corregido"
  ${nombre} --uncommit
  ${nombre} --pull                     # si diverge, pregunta la estrategia
  ${nombre} --pull --rebase            # reaplicar commits locales
  ${nombre} --pull --merge             # crear commit de fusión
  ${nombre} --menu                     # menú interactivo
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
# Carpeta donde está el propio script (resuelve enlaces simbólicos).
_directorio_script() {
  local origen="${BASH_SOURCE[0]}" real
  real="$(readlink -f "$origen" 2>/dev/null)" || real="$origen"
  printf '%s' "$(dirname "$real")"
}

# Copia las plantillas que estén junto al script. Nunca sobrescribe archivos
# existentes: solo crea los que faltan.
_copiar_plantillas() {
  local plantillas archivo origen destino
  local creados=0 existentes=0 faltantes=0

  plantillas="$(_directorio_script)/plantillas"
  if [[ ! -d "$plantillas" ]]; then
    warn "No se encontró la carpeta de plantillas: ${plantillas}"
    return 1
  fi

  local -a archivos=(
    ".clineignore"
    ".clinerules"
    ".gitattributes"
    ".gitignore"
    "AGENTS.md"
    "opencode.json"
    ".secrets/litellm_api_key"
    "custom_scripts/excluir_archivos.sh"
    "custom_scripts/listar_archivos_por_excluir.sh"
  )

  for archivo in "${archivos[@]}"; do
    origen="$plantillas/$archivo"
    destino="$archivo"

    if [[ ! -e "$origen" ]]; then
      warn "Falta la plantilla: ${archivo}"
      faltantes=$((faltantes + 1))
      continue
    fi

    if [[ -e "$destino" ]]; then
      info "Ya existe, se conserva: ${archivo}"
      existentes=$((existentes + 1))
      continue
    fi

    if ! mkdir -p "$(dirname "$destino")"; then
      error "No se pudo crear la carpeta de: ${archivo}"
      continue
    fi

    if ! cp -p "$origen" "$destino"; then
      error "No se pudo crear: ${archivo}"
      continue
    fi

    case "$archivo" in
      .secrets/*)
        chmod 700 .secrets 2>/dev/null
        chmod 600 "$destino" 2>/dev/null
        ;;
      *.sh)
        chmod +x "$destino" 2>/dev/null
        ;;
    esac

    ok "Creado: ${archivo}"
    creados=$((creados + 1))
  done

  echo
  info "Plantillas: ${creados} creada(s), ${existentes} conservada(s), ${faltantes} faltante(s)."
}

inicializar() {
  if es_repo; then
    ok "El directorio ya es un repositorio git."
  else
    if ! git init -q; then
      error "Falló 'git init'."
      return 1
    fi
    git symbolic-ref HEAD refs/heads/main
    ok "Repositorio inicializado con la rama main."
  fi

  _copiar_plantillas
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
# Explica las estrategias de integración cuando las ramas han divergido.
_ayuda_estrategias() {
  cat <<'AYUDA'
  r) Rebase: tus commits locales se reaplican sobre los del remoto. El historial
     queda lineal, sin commits de fusión. Reescribe tus commits locales, así que
     no conviene si ya los compartiste con otros. Este comando usa la opción
     --rebase en el comando git.
  m) Merge: se crea un commit de fusión que une las dos historias. Conserva el
     historial tal cual ocurrió. Es lo más seguro si no estás seguro. Este
     comando usa la opción --no-rebase en el comando git.
  c) Cancelar: no se cambia nada en el repositorio.
AYUDA
}

# Pregunta la estrategia cuando hay divergencia. Deja el resultado en la
# variable global ESTRATEGIA_PULL: "rebase", "merge" o "cancelar".
_preguntar_estrategia() {
  local atras="$1" adelante="$2" respuesta
  ESTRATEGIA_PULL=""

  if [[ ! -t 0 ]]; then
    error "No se puede preguntar la estrategia sin terminal interactiva."
    error "Use: $(basename "$0") --pull --rebase   o   $(basename "$0") --pull --merge"
    return 1
  fi

  warn "Las ramas han divergido: ${adelante} commit(s) local(es) y ${atras} commit(s) remoto(s)."
  printf '%s\n' "¿Cómo quieres integrarlas?"
  _ayuda_estrategias

  while true; do
    if ! _leer_linea 'Opción [r/m/c] (o ? para ver la ayuda): ' respuesta; then
      ESTRATEGIA_PULL="cancelar"
      return 0
    fi
    case "${respuesta,,}" in
      r|rebase)             ESTRATEGIA_PULL="rebase";   return 0 ;;
      m|merge)              ESTRATEGIA_PULL="merge";    return 0 ;;
      c|cancelar|cancel)    ESTRATEGIA_PULL="cancelar"; return 0 ;;
      $'\e')                ESTRATEGIA_PULL="cancelar"; return 0 ;;
      '?')                  _ayuda_estrategias ;;
      "")                   ;;
      *)                    warn "Opción no válida. Escriba r, m, c o ?." ;;
    esac
  done
}

pull() {
  requerir_repo

  local estrategia="" arg
  for arg in "$@"; do
    case "$arg" in
      --rebase)              estrategia="rebase" ;;
      --merge|--no-rebase)   estrategia="merge" ;;
      *)
        error "Opción no válida para --pull: $arg"
        error "Use: $(basename "$0") --pull [--rebase|--merge]"
        return 1
        ;;
    esac
  done

  local upstream atras adelante recien_actualizado=0

  if ! tiene_upstream; then
    # Sin upstream: se intenta vincular a <remoto>/<rama> automáticamente.
    if ! asegurar_upstream; then
      return 1
    fi
    recien_actualizado=1
  fi

  upstream="$(upstream_actual)"

  if (( recien_actualizado == 0 )); then
    if ! actualizar_remoto "$upstream"; then
      error "No se pudo actualizar el remoto de '${upstream}'."
      return 1
    fi
  fi

  read -r atras adelante < <(contar_divergencia "$upstream")

  # Sin commits nuevos en el remoto: no hay nada que reconciliar.
  if [[ "$atras" -eq 0 ]]; then
    git pull
    return
  fi

  # Solo el remoto tiene commits nuevos: avance rápido, no hay divergencia.
  if [[ "$adelante" -eq 0 ]]; then
    info "El remoto tiene ${atras} commit(s) nuevos. Integrando por avance rápido..."
    git pull
    return
  fi

  # Ramas divergidas: usar la estrategia indicada o preguntar.
  if [[ -z "$estrategia" ]]; then
    _preguntar_estrategia "$atras" "$adelante" || return 1
    estrategia="$ESTRATEGIA_PULL"
  fi

  case "$estrategia" in
    cancelar)
      info "Operación cancelada. No se ha modificado el repositorio."
      return 0
      ;;
    rebase)
      info "Integrando con rebase (git pull --rebase)..."
      git pull --rebase && ok "Cambios integrados con rebase."
      ;;
    merge)
      if sin_ancestro_comun "$upstream"; then
        info "Las historias no comparten ancestro; se integran con --allow-unrelated-histories."
        git pull --no-rebase --no-edit --allow-unrelated-histories && ok "Cambios integrados con merge."
      else
        info "Integrando con merge (git pull --no-rebase)..."
        git pull --no-rebase --no-edit && ok "Cambios integrados con merge."
      fi
      ;;
  esac
}

push() {
  requerir_repo
  local rama remoto upstream atras adelante

  if [[ -z "$(git remote 2>/dev/null)" ]]; then
    error "No hay ningún remoto configurado. Use: $(basename "$0") --remote add <url>"
    return 1
  fi

  rama="$(rama_actual)"
  remoto="$(remoto_principal)" || {
    error "No se pudo determinar el remoto principal."
    return 1
  }

  # Sin upstream: se comprueba si la rama ya existe en el remoto antes de
  # publicarla, para no chocar con commits remotos (non-fast-forward).
  if ! tiene_upstream; then
    info "Actualizando referencias del remoto '${remoto}' (git fetch)..."
    if ! git fetch "$remoto"; then
      error "No se pudo actualizar el remoto '${remoto}'."
      return 1
    fi

    if git show-ref --verify --quiet "refs/remotes/${remoto}/${rama}"; then
      upstream="${remoto}/${rama}"
      read -r atras adelante < <(contar_divergencia "$upstream")

      if [[ "$atras" -gt 0 ]]; then
        warn "El remoto '${upstream}' tiene ${atras} commit(s) que no tienes localmente."
        if [[ "$adelante" -gt 0 ]]; then
          warn "Las ramas han divergido (${adelante} commit(s) solo en local)."
        fi
        error "Ejecute $(basename "$0") --pull para integrar los cambios antes de enviar."
        return 1
      fi
    fi

    git push -u "$remoto" "$rama"
    return
  fi

  upstream="$(upstream_actual)"

  if ! actualizar_remoto "$upstream"; then
    error "No se pudo actualizar el remoto de '${upstream}'."
    return 1
  fi

  read -r atras adelante < <(contar_divergencia "$upstream")

  if [[ "$atras" -gt 0 ]]; then
    warn "El remoto '${upstream}' tiene ${atras} commit(s) que no tienes localmente."
    if [[ "$adelante" -gt 0 ]]; then
      warn "Las ramas han divergido (${adelante} commit(s) solo en local)."
    fi
    error "Ejecute $(basename "$0") --pull para integrar los cambios antes de enviar."
    return 1
  fi

  git push
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

status_completo() {
  requerir_repo
  git status

  if ! tiene_upstream; then
    return 0
  fi

  local upstream atras adelante
  upstream="$(upstream_actual)"
  read -r atras adelante < <(contar_divergencia "$upstream")

  if [[ "$atras" -gt 0 || "$adelante" -gt 0 ]]; then
    echo
    info "Resumen respecto a '${upstream}': ${adelante} commit(s) solo en local, ${atras} commit(s) solo en el remoto."
    if [[ "$atras" -gt 0 && "$adelante" -gt 0 ]]; then
      warn "Las ramas han divergido."
      info "Ejecute: $(basename "$0") --pull   (le preguntará rebase, merge o cancelar)"
    elif [[ "$atras" -gt 0 ]]; then
      info "Ejecute: $(basename "$0") --pull   para traer los cambios del remoto"
    else
      info "Ejecute: $(basename "$0") --push   para enviar tus commits"
    fi
  fi
}

# ---------- Diferencias (delta --side-by-side) ----------
requerir_delta() {
  if ! command -v delta >/dev/null 2>&1; then
    error "No se encontró el comando 'delta'."
    error "Instálelo desde https://github.com/dandavison/delta e inténtelo de nuevo."
    return 1
  fi
}

# Referencia local de comparación: HEAD o, si aún no hay commits, el árbol vacío.
_rev_local() {
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
    printf 'HEAD'
  else
    git hash-object -t tree /dev/null
  fi
}

# Lista de archivos modificados, preparados o nuevos (sin duplicados).
archivos_para_diff() {
  {
    git diff --name-only "$1"
    git ls-files --others --exclude-standard
  } | awk 'NF && !visto[$0]++'
}

# Muestra el diff de un archivo contra la referencia indicada.
_diff_archivo() {
  local base="$1" archivo="$2" salida

  if git cat-file -e "${base}:${archivo}" 2>/dev/null; then
    salida="$(git --no-pager diff "$base" -- "$archivo")"
  else
    # El archivo no existe en la referencia: se muestra completo como nuevo.
    salida="$(git --no-pager diff --no-index -- /dev/null "$archivo" || true)"
  fi

  if [[ -z "${salida//[[:space:]]/}" ]]; then
    info "Sin diferencias en: ${archivo}"
    return 0
  fi

  info "Diferencias en: ${archivo}"
  printf '%s\n' "$salida" | delta --side-by-side
}

# Recorre todos los archivos cambiados y muestra su diff contra la referencia.
_diff_todos() {
  local base="$1" f
  local -a archivos=()

  mapfile -t archivos < <(archivos_para_diff "$base")
  if [[ ${#archivos[@]} -eq 0 ]]; then
    info "No hay archivos modificados o nuevos."
    return 0
  fi

  for f in "${archivos[@]}"; do
    _diff_archivo "$base" "$f"
  done
}

showdiff_local() {
  requerir_repo
  requerir_delta || return 1

  local base archivo="${1:-}"
  base="$(_rev_local)"

  if [[ -z "$archivo" ]]; then
    _diff_todos "$base"
    return 0
  fi

  if [[ ! -e "$archivo" ]] && ! git cat-file -e "${base}:${archivo}" 2>/dev/null; then
    error "El archivo '$archivo' no existe en el disco ni en el repositorio local."
    return 1
  fi

  _diff_archivo "$base" "$archivo"
}

showdiff_remote() {
  requerir_repo
  requerir_delta || return 1

  if ! tiene_upstream; then
    error "La rama '$(rama_actual)' no tiene remoto (upstream) configurado."
    error "Configúrelo ejecutando: $(basename "$0") --push"
    return 1
  fi

  local upstream remoto archivo="${1:-}"
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  remoto="${upstream%%/*}"

  info "Actualizando referencias del remoto '${remoto}' (git fetch)..."
  if ! git fetch "$remoto"; then
    error "No se pudo actualizar el remoto '${remoto}'."
    return 1
  fi

  if [[ -z "$archivo" ]]; then
    _diff_todos "$upstream"
    return 0
  fi

  if [[ ! -e "$archivo" ]] && ! git cat-file -e "${upstream}:${archivo}" 2>/dev/null; then
    error "El archivo '$archivo' no existe en el disco ni en '${upstream}'."
    return 1
  fi

  _diff_archivo "$upstream" "$archivo"
}

# ---------- Prompt ----------
# Muestra: [rama] (cambios): rama en verde negrita y número de cambios en
# amarillo. Las secuencias de color se envuelven con \001 ... \002 (marcadores
# de "no imprimible" de readline) para que no descuadren el cursor.
_np() { [[ -n "${1:-}" ]] && printf '\001%s\002' "$1"; return 0; }
# Reset entre segmentos: solo si hay algún color configurado.
_np_reset() {
  [[ -n "${C_RAMA_PROMPT}${C_CAMBIOS_PROMPT}" ]] && printf '\001%s\002' "$C_PROMPT_RESET"
  return 0
}

actualizar_prompt() {
  local rama cambios res
  if es_repo; then
    rama="$(rama_actual)"
    cambios="$(cantidad_cambios)"
    res="$(_np_reset)"
    GIT_AUTO_PS1="$(_np "$C_RAMA_PROMPT")${rama}${res} $(_np "$C_CAMBIOS_PROMPT")(${cambios})${res} "
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

_activar_hook_prompt_array() {
  local previas=("${PROMPT_COMMAND[@]}")
  PROMPT_COMMAND=(actualizar_prompt "${previas[@]}")
}

_activar_hook_prompt_cadena() {
  local previa="${PROMPT_COMMAND:-}" nuevo="actualizar_prompt"
  [[ -n "$previa" ]] && nuevo+="; ${previa}"
  printf -v PROMPT_COMMAND '%s' "$nuevo"
}

activar_prompt() {
  actualizar_prompt
  if ! _prompt_command_ya_incluye_hook; then
    if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
      _activar_hook_prompt_array
    else
      _activar_hook_prompt_cadena
    fi
  fi
  PS1='\u@\h:\w ${GIT_AUTO_PS1}\$ '
  ok "Prompt de git_auto activado en esta sesión."
}

# ============================================================
# Menú interactivo (--menu)
# ============================================================
# Colores del menú: selección (letra negra sobre fondo cian) y descripción.
C_MENU_SELECCION=$'\e[1;30;46m'
C_MENU_DESC=$'\e[35m'

# Opciones del menú. Los índices de los arrays se corresponden entre sí.
_menu_inicializar_opciones() {
  _MENU_IDS=(       1             2                3          4            5
                    6           7                8                 9
                    10            11           12           13          14
                    15            16              17               18          0 )
  _MENU_ETIQUETAS=( resumen       status           log        ramas        "nueva rama"
                    remotos     "anadir remoto"  "cambiar URL"     "eliminar remoto"
                    commit        amend            uncommit   pull        push
                    init          "diff local"     "diff remoto"     ayuda       salir )
  _MENU_DESC=(
    "Muestra un resumen del estado del repositorio (rama, remoto y cambios)."
    "Muestra el estado completo del repositorio y la divergencia con el remoto."
    "Muestra los últimos commits; puedes indicar cuántos (10 por defecto)."
    "Lista las ramas y permite cambiar a otra."
    "Crea una rama nueva y cambia a ella."
    "Muestra los remotos configurados."
    "Añade un remoto nuevo; pide la URL y el nombre (origin por defecto)."
    "Cambia la URL de un remoto existente."
    "Elimina un remoto existente."
    "Añade todos los cambios y hace commit; pide el mensaje."
    "Corrige el último commit; pide el mensaje."
    "Deshace el último commit y conserva los cambios en staging."
    "Trae cambios del remoto; si hay divergencia pregunta rebase, merge o cancelar."
    "Envía tus commits al remoto; avisa si hay que hacer pull antes."
    "Inicializa un repositorio git con la rama main en la carpeta actual."
    "Lista los archivos modificados y muestra su diff local; se elige por número o nombre."
    "Lista los archivos con cambios frente al remoto y muestra su diff; se elige por número o nombre."
    "Muestra la ayuda completa del script."
    "Sale del menú."
  )
  _MENU_ACCIONES=(
    _menu_accion_resumen
    _menu_accion_status
    _menu_accion_log
    _menu_accion_ramas
    _menu_accion_nueva_rama
    _menu_accion_mostrar_remotos
    _menu_accion_agregar_remoto
    _menu_accion_seturl_remoto
    _menu_accion_eliminar_remoto
    _menu_accion_commit
    _menu_accion_amend
    _menu_accion_uncommit
    _menu_accion_pull
    _menu_accion_push
    _menu_accion_init
    _menu_accion_diff_local
    _menu_accion_diff_remote
    _menu_accion_ayuda
    _menu_accion_salir
  )
}

_menu_restaurar() {
  printf '\e[?25h'
  trap - EXIT INT TERM
}

_menu_salir() {
  _menu_restaurar
  exit 0
}

# Lee una tecla y deja el resultado en _TECLA:
# ARRIBA, ABAJO, ENTER, ESC, EOF, NUM:<dígito> u OTRO.
_menu_leer_resto_escape() {
  local c2 c3
  _ESC_ARROW=""
  IFS= read -rsn1 -t 0.05 c2 || return 1
  [[ "$c2" == "[" || "$c2" == "O" ]] || return 1
  IFS= read -rsn1 -t 0.05 c3 || return 1
  case "$c3" in
    A) _ESC_ARROW="ARRIBA" ;;
    B) _ESC_ARROW="ABAJO" ;;
  esac
  return 0
}

_menu_leer_tecla() {
  local c
  _TECLA=""
  if ! IFS= read -rsn1 c; then
    _TECLA="EOF"
    return
  fi
  case "$c" in
    $'\e')
      if _menu_leer_resto_escape; then
        case "$_ESC_ARROW" in
          ARRIBA) _TECLA="ARRIBA" ;;
          ABAJO)  _TECLA="ABAJO" ;;
          *)      _TECLA="OTRO" ;;
        esac
      else
        _TECLA="ESC"
      fi
      ;;
    "")    _TECLA="ENTER" ;;
    [0-9]) _TECLA="NUM:${c}" ;;
    *)     _TECLA="OTRO" ;;
  esac
}

# Lee una línea con edición básica. Devuelve 1 si se pulsa ESC (cancelar).
_leer_linea() {
  local prompt="$1" destino="$2" texto="" tecla
  printf '%s' "$prompt"
  while true; do
    if ! IFS= read -rsn1 tecla; then
      printf '\n'
      return 1
    fi
    case "$tecla" in
      $'\e')
        printf '\n'
        return 1
        ;;
      "")
        printf '\n'
        [[ -n "$destino" ]] && printf -v "$destino" '%s' "$texto"
        return 0
        ;;
      $'\x7f'|$'\b')
        if [[ -n "$texto" ]]; then
          texto="${texto%?}"
          printf '\b \b'
        fi
        ;;
      *)
        texto+="$tecla"
        printf '%s' "$tecla"
        ;;
    esac
  done
}

_menu_hay_prefijo() {
  local prefijo="$1" id
  for id in "${_MENU_IDS[@]}"; do
    [[ ${#id} -gt 1 && "${id:0:1}" == "$prefijo" ]] && return 0
  done
  return 1
}

_menu_indice_de_id() {
  local id="$1" i
  for i in "${!_MENU_IDS[@]}"; do
    if [[ "${_MENU_IDS[$i]}" == "$id" ]]; then
      _MENU_IDX="$i"
      return 0
    fi
  done
  return 1
}

_menu_esperar_enter() {
  while true; do
    _menu_leer_tecla
    case "$_TECLA" in
      ENTER|ESC|EOF) return 0 ;;
    esac
  done
}

# Texto con el número de cambios sin commit (modificados, preparados y nuevos).
_menu_texto_cambios() {
  local cambios
  cambios="$(cantidad_cambios)"
  if [[ "$cambios" -eq 0 ]]; then
    printf 'sin cambios pendientes'
  elif [[ "$cambios" -eq 1 ]]; then
    printf '1 cambio sin commit'
  else
    printf '%s cambios sin commit' "$cambios"
  fi
}

# Cabecera del menú: rama, estado respecto al remoto y cambios sin commit.
_menu_estado_rama() {
  local rama upstream atras adelante estado
  if ! es_repo; then
    printf 'Rama: (no es un repositorio git)'
    return
  fi
  rama="$(rama_actual)"

  if tiene_upstream; then
    upstream="$(upstream_actual)"
    read -r atras adelante < <(contar_divergencia "$upstream")
    if [[ "$atras" -eq 0 && "$adelante" -eq 0 ]]; then
      estado="al día con ${upstream}"
    else
      estado="↑ ${adelante} para subir   ·   ↓ ${atras} para bajar"
    fi
  elif [[ -n "$(git remote 2>/dev/null)" ]]; then
    estado="sin upstream en '${rama}'"
  else
    estado="sin remoto configurado"
  fi

  printf 'Rama: %s   ·   %s   ·   %s' "$rama" "$estado" "$(_menu_texto_cambios)"
}

_menu_dibujar() {
  local i
  printf '\e[H\e[2J'
  printf '%sgit_auto - menú principal%s\n' "$C_NEGRITA" "$C_RESET"
  printf '%s%s%s\n\n' "$C_CIAN" "$(_menu_estado_rama)" "$C_RESET"
  for i in "${!_MENU_IDS[@]}"; do
    if (( i == _MENU_SEL )); then
      printf '%s  > %2s) %-22s%s\n' "$C_MENU_SELECCION" "${_MENU_IDS[$i]}" "${_MENU_ETIQUETAS[$i]}" "$C_RESET"
    else
      printf '    %2s) %s\n' "${_MENU_IDS[$i]}" "${_MENU_ETIQUETAS[$i]}"
    fi
  done
  printf '\n  %s\n' "-------------------------------------------------------------------------"
  printf '%s  %s%s\n' "$C_MENU_DESC" "${_MENU_DESC[$_MENU_SEL]}" "$C_RESET"
  printf '  %s\n' "-------------------------------------------------------------------------"
  printf '  ↑/↓ mover · ENTER ejecutar · número elige · 0/ESC salir\n'
}

_menu_ejecutar() {
  local idx="$1" fn="${_MENU_ACCIONES[$1]}" estado
  printf '\e[?25h\e[H\e[2J'
  printf '%s> %s) %s%s\n\n' "$C_NEGRITA" "${_MENU_IDS[$idx]}" "${_MENU_ETIQUETAS[$idx]}" "$C_RESET"
  ( export GIT_PAGER=cat PAGER=cat; "$fn" )
  estado=$?
  echo
  if (( estado == 2 )); then
    warn "Operación cancelada."
    return
  fi
  printf 'Pulse ENTER para volver al menú...'
  _menu_esperar_enter
  printf '\n\e[?25l'
}

# Selección por número. Si el número puede continuar (p. ej. 1 -> 10..18),
# espera un segundo una segunda cifra antes de ejecutar la opción de una cifra.
_menu_por_numero() {
  local primero="$1" segundo="" idx_uno="" hay_uno=0

  if _menu_indice_de_id "$primero"; then
    idx_uno="$_MENU_IDX"
    hay_uno=1
  fi

  if ! _menu_hay_prefijo "$primero"; then
    if (( hay_uno )); then
      _menu_ejecutar "$idx_uno"
    else
      warn "No existe la opción ${primero}."
    fi
    return
  fi

  if ! IFS= read -rsn1 -t 1 segundo; then
    if (( hay_uno )); then
      _menu_ejecutar "$idx_uno"
    else
      warn "No existe la opción ${primero}."
    fi
    return
  fi

  case "$segundo" in
    [0-9])
      if _menu_indice_de_id "${primero}${segundo}"; then
        _menu_ejecutar "$_MENU_IDX"
      else
        warn "No existe la opción ${primero}${segundo}."
      fi
      ;;
    $'\e')
      if _menu_leer_resto_escape; then
        case "$_ESC_ARROW" in
          ARRIBA) (( _MENU_SEL > 0 )) && _MENU_SEL=$((_MENU_SEL - 1)) ;;
          ABAJO)  (( _MENU_SEL < ${#_MENU_IDS[@]} - 1 )) && _MENU_SEL=$((_MENU_SEL + 1)) ;;
        esac
      else
        _menu_salir
      fi
      ;;
    *)
      if (( hay_uno )); then
        _menu_ejecutar "$idx_uno"
      else
        warn "No existe la opción ${primero}."
      fi
      ;;
  esac
}

# ---------- Acciones del menú ----------
_menu_accion_resumen()        { resumen; }
_menu_accion_status()         { status_completo; }
_menu_accion_mostrar_remotos() { mostrar_remoto; }
_menu_accion_pull()           { pull; }
_menu_accion_push()           { push; }
_menu_accion_uncommit()       { uncommit; }
_menu_accion_init()           { inicializar; }
_menu_accion_ayuda()          { mostrar_ayuda; }
_menu_accion_salir()          { return 0; }

_menu_accion_log() {
  local n
  _leer_linea "Número de commits [10]: " n || return 2
  ver_log "${n:-10}"
}

_menu_accion_ramas() {
  mostrar_rama || return $?
  local rama
  _leer_linea "Rama a la que cambiar (ENTER para solo ver): " rama || return 2
  [[ -z "$rama" ]] && return 0
  cambiar_rama "$rama"
}

_menu_accion_nueva_rama() {
  local rama
  _leer_linea "Nombre de la nueva rama: " rama || return 2
  if [[ -z "$rama" ]]; then
    warn "No se indicó ningún nombre."
    return 1
  fi
  nueva_rama "$rama"
}

_menu_accion_agregar_remoto() {
  local url nombre
  _leer_linea "URL del remoto: " url || return 2
  if [[ -z "$url" ]]; then
    warn "No se indicó ninguna URL."
    return 1
  fi
  _leer_linea "Nombre del remoto [origin]: " nombre || return 2
  agregar_remoto "$url" "${nombre:-origin}"
}

_menu_accion_seturl_remoto() {
  local url nombre
  _leer_linea "Nueva URL del remoto: " url || return 2
  if [[ -z "$url" ]]; then
    warn "No se indicó ninguna URL."
    return 1
  fi
  _leer_linea "Nombre del remoto [origin]: " nombre || return 2
  cambiar_url_remoto "$url" "${nombre:-origin}"
}

_menu_accion_eliminar_remoto() {
  local nombre
  _leer_linea "Nombre del remoto a eliminar [origin]: " nombre || return 2
  eliminar_remoto "${nombre:-origin}"
}

_menu_accion_commit() {
  local mensaje
  _leer_linea "Mensaje del commit (ENTER usa fecha y hora): " mensaje || return 2
  commit "$mensaje"
}

_menu_accion_amend() {
  local mensaje
  _leer_linea "Mensaje corregido (ENTER usa fecha y hora): " mensaje || return 2
  amend "$mensaje"
}

_menu_mostrar_archivos() {
  local i
  info "Archivos modificados o nuevos (${#_ARCHIVOS_MENU[@]}):"
  for i in "${!_ARCHIVOS_MENU[@]}"; do
    printf '  %2d) %s\n' "$((i + 1))" "${_ARCHIVOS_MENU[$i]}"
  done
  echo
}

# Traduce la entrada del usuario (número de la lista o nombre) al archivo.
# Sin entrada devuelve vacío, que significa "todos".
_menu_resolver_archivo() {
  local entrada="$1" idx
  if [[ -z "$entrada" ]]; then
    return 0
  fi
  if [[ "$entrada" =~ ^[0-9]+$ ]]; then
    idx=$((10#$entrada))
    if (( idx >= 1 && idx <= ${#_ARCHIVOS_MENU[@]} )); then
      printf '%s' "${_ARCHIVOS_MENU[$((idx - 1))]}"
      return 0
    fi
    warn "Número de archivo no válido: ${entrada}"
    return 1
  fi
  printf '%s' "$entrada"
}

_menu_accion_diff_local() {
  requerir_delta || return 1
  local base archivo entrada
  base="$(_rev_local)"
  mapfile -t _ARCHIVOS_MENU < <(archivos_para_diff "$base")

  if [[ ${#_ARCHIVOS_MENU[@]} -eq 0 ]]; then
    info "No hay archivos modificados o nuevos."
    return 0
  fi

  _menu_mostrar_archivos
  _leer_linea "Número del archivo o nombre (ENTER para todos, ESC para volver): " entrada || return 2
  archivo="$(_menu_resolver_archivo "$entrada")" || return 1

  if [[ -z "$archivo" ]]; then
    _diff_todos "$base"
  else
    _diff_archivo "$base" "$archivo"
  fi
}

_menu_accion_diff_remote() {
  requerir_delta || return 1

  if ! tiene_upstream; then
    error "La rama '$(rama_actual)' no tiene remoto (upstream) configurado."
    error "Configúrelo ejecutando: $(basename "$0") --push"
    return 1
  fi

  local upstream remoto archivo entrada
  upstream="$(upstream_actual)"
  remoto="$(remoto_del_upstream "$upstream")"

  info "Actualizando referencias del remoto '${remoto}' (git fetch)..."
  if ! git fetch "$remoto"; then
    error "No se pudo actualizar el remoto '${remoto}'."
    return 1
  fi

  mapfile -t _ARCHIVOS_MENU < <(archivos_para_diff "$upstream")

  if [[ ${#_ARCHIVOS_MENU[@]} -eq 0 ]]; then
    info "No hay archivos modificados o nuevos respecto a '${upstream}'."
    return 0
  fi

  _menu_mostrar_archivos
  _leer_linea "Número del archivo o nombre (ENTER para todos, ESC para volver): " entrada || return 2
  archivo="$(_menu_resolver_archivo "$entrada")" || return 1

  if [[ -z "$archivo" ]]; then
    _diff_todos "$upstream"
  else
    _diff_archivo "$upstream" "$archivo"
  fi
}

menu_principal() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    error "El menú requiere una terminal interactiva."
    error "Use las opciones directamente: $(basename "$0") --help"
    return 1
  fi

  _menu_inicializar_opciones
  _MENU_SEL=0
  printf '\e[?25l'
  trap 'menu_restaurar_trap' INT TERM
  trap '_menu_restaurar' EXIT

  while true; do
    _menu_dibujar
    _menu_leer_tecla
    case "$_TECLA" in
      ARRIBA) (( _MENU_SEL > 0 )) && _MENU_SEL=$((_MENU_SEL - 1)) ;;
      ABAJO)  (( _MENU_SEL < ${#_MENU_IDS[@]} - 1 )) && _MENU_SEL=$((_MENU_SEL + 1)) ;;
      ENTER)  _menu_ejecutar "$_MENU_SEL" ;;
      ESC|EOF) _menu_salir ;;
      NUM:0)  _menu_salir ;;
      NUM:*)  _menu_por_numero "${_TECLA#NUM:}" ;;
    esac
  done
}

menu_restaurar_trap() {
  _menu_restaurar
  exit 130
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
    info "Menú interactivo: $(basename "$0") --menu"
    ;;
  -h|--help)   mostrar_ayuda ;;
  --menu)      menu_principal ;;
  --init)      inicializar ;;
  --commit)    shift; commit "$@" ;;
  --amend)     shift; amend "$@" ;;
  --uncommit)  uncommit ;;
  --pull)      shift; pull "$@" ;;
  --push)      push ;;
  --branch)
    shift
    if [[ $# -eq 0 ]]; then mostrar_rama; else cambiar_rama "$1"; fi
    ;;
  --newbranch) shift; nueva_rama "${1:-}" ;;
  --remote)    shift; comando_remoto "$@" ;;
  --log)       shift; ver_log "${1:-10}" ;;
  --status)    status_completo ;;
  --showdiff-local)  shift; showdiff_local "${1:-}" ;;
  --showdiff-remote) shift; showdiff_remote "${1:-}" ;;
  *)
    error "Opción no válida: $1"
    mostrar_ayuda
    exit 1
    ;;
esac