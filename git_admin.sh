#!/usr/bin/env bash
set -uo pipefail

MENSAJE_COMMIT_POR_DEFECTO="${MENSAJE_COMMIT_POR_DEFECTO:-Actualizacion automatica $(date '+%Y-%m-%d %H:%M')}"
REMOTO_POR_DEFECTO="${REMOTO_POR_DEFECTO:-origin}"
RAMA_PRINCIPAL="${RAMA_PRINCIPAL:-main}"
VISIBILIDAD_POR_DEFECTO="${VISIBILIDAD_POR_DEFECTO:-private}"
ARCHIVOS_IGNORAR_POR_DEFECTO="${ARCHIVOS_IGNORAR_POR_DEFECTO:-bin/ obj/ .vs/ node_modules/ *.log *.tmp *.user *.suo .DS_Store Thumbs.db}"

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

pausa() {
  local _
  read -rp "Presione Enter para continuar..." _ || true
}

confirmar() {
  local respuesta=""
  read -rp "$1 [S/n]: " respuesta || true
  [[ -z "$respuesta" || "$respuesta" =~ ^[SsYy]$ ]]
}

confirmar_texto() {
  local esperado="$1"
  local pregunta="$2"
  local respuesta=""
  read -rp "$pregunta " respuesta || true
  [[ "$respuesta" == "$esperado" ]]
}

requiere_git() {
  if ! command -v git >/dev/null 2>&1; then
    error "Git no está instalado."
    exit 1
  fi
}

es_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

exigir_repo() {
  if ! es_repo; then
    warn "No hay un repositorio Git en este directorio."
    return 1
  fi
}

hay_cambios() {
  [[ -n "$(git status --porcelain 2>/dev/null)" ]]
}

rama_actual() {
  local rama=""
  local sha=""
  rama="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [[ -n "$rama" ]]; then
    printf '%s' "$rama"
  else
    sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
    printf '(HEAD desacoplado %s)' "${sha:-?}"
  fi
}

remoto_efectivo() {
  local primero=""
  if git remote get-url "$REMOTO_POR_DEFECTO" >/dev/null 2>&1; then
    printf '%s' "$REMOTO_POR_DEFECTO"
    return 0
  fi
  primero="$(git remote | head -n 1)"
  if [[ -n "$primero" ]]; then
    printf '%s' "$primero"
    return 0
  fi
  return 1
}

pedir_remoto() {
  local remoto=""
  read -rp "Nombre del remoto [$REMOTO_POR_DEFECTO]: " remoto || true
  printf '%s' "${remoto:-$REMOTO_POR_DEFECTO}"
}

identidad_ok() {
  [[ -n "$(git config user.name 2>/dev/null || true)" && -n "$(git config user.email 2>/dev/null || true)" ]]
}

paginar() {
  if command -v less >/dev/null 2>&1 && [[ -t 1 ]]; then
    "$@" | less -R
  else
    "$@"
  fi
}

# Indica si el visor 'delta' está disponible en el sistema.
tiene_delta() {
  command -v delta >/dev/null 2>&1
}

# Muestra un diff con 'delta' en modo lado a lado (--side-by-side).
# Si 'delta' no está instalado, recurre al paginador tradicional con color.
ver_diff() {
  if tiene_delta; then
    git --no-pager diff "$@" | delta --side-by-side
  else
    paginar git --no-pager diff --color=always "$@"
  fi
}

# Igual que ver_diff pero para 'git show' (metadatos + diff del commit).
ver_show() {
  if tiene_delta; then
    git --no-pager show "$@" | delta --side-by-side
  else
    paginar git --no-pager show --color=always "$@"
  fi
}

mostrar_cabecera() {
  local rama=""
  local cambios="0"
  local remoto=""
  if es_repo; then
    rama="$(rama_actual)"
    cambios="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
    remoto="$(git remote get-url "$REMOTO_POR_DEFECTO" 2>/dev/null || true)"
    if [[ -z "$remoto" ]]; then
      remoto="$(git remote | head -n 1)"
    fi
    if [[ -z "$remoto" ]]; then
      remoto="(sin remoto)"
    fi
    printf '\n%s[%s]%s\n' "$C_NEGRITA" "$PWD" "$C_RESET"
    printf '%sRama: %s | Cambios: %s | Remoto: %s%s\n' "$C_CIAN" "$rama" "$cambios" "$remoto" "$C_RESET"
  else
    printf '\n%s[%s]%s\n' "$C_NEGRITA" "$PWD" "$C_RESET"
    printf '%sSin repositorio Git. Use la opción 2 para inicializarlo.%s\n' "$C_AMARILLO" "$C_RESET"
  fi
}

mostrar_menu() {
  # Cada entrada: "tipo|texto"
  #   B = título (negrita)
  #   N = ítem normal
  #   S = separador horizontal
  local -a menu=(
    "B|--- Menú Git ---"
    "N|  1) Ver estado"
    "N|  2) Inicializar repositorio"
    "N|  3) Confirmar cambios (commit)"
    "N|  4) Integrar repositorio remoto (GitHub/GitLab)"
    "N|  5) Push (subir cambios)"
    "N|  6) Pull (traer cambios)"
    "N|  7) Ver diferencias"
    "N|  8) Cambiar de rama"
    "N|  9) Crear rama"
    "N| 10) Fusionar rama"
    "N| 11) Fetch (actualizar referencias remotas)"
    "N| 12) Historial (log)"
    "N| 13) Stash (guardar/recuperar cambios)"
    "N| 14) Descartar cambios locales"
    "N| 15) Configurar identidad de Git"
    "S|"
    "B|--- Utilidades ---"
    "N| 16) Abrir shell interactivo (volver con \"exit\")"
    "N| 17) Editar archivo con vi"
    "N| 18) Abrir Midnight Commander (mc)"
    "N|  0) Salir"
  )

  # 1) Ancho visible máximo (sin contar códigos ANSI)
  local max=0 entrada texto tipo
  for entrada in "${menu[@]}"; do
    tipo="${entrada%%|*}"
    texto="${entrada#*|}"
    [[ "$tipo" == "S" ]] && continue
    (( ${#texto} > max )) && max=${#texto}
  done

  # 2) Ancho total del interior = contenido + 2 espacios de padding por lado
  local ancho=$((max + 4))
  local horizontal="" i
  for ((i=0; i<ancho; i++)); do horizontal+="─"; done

  # 3) Borde superior
  printf '%s┌%s┐%s\n' "$C_NEGRITA" "$horizontal" "$C_RESET"

  # 4) Filas
  for entrada in "${menu[@]}"; do
    tipo="${entrada%%|*}"
    texto="${entrada#*|}"

    if [[ "$tipo" == "S" ]]; then
      printf '%s├%s┤%s\n' "$C_NEGRITA" "$horizontal" "$C_RESET"
      continue
    fi

    local padding=$(( max - ${#texto} ))
    local relleno=""
    if (( padding > 0 )); then
      printf -v relleno '%*s' "$padding" ''
    fi

    if [[ "$tipo" == "B" ]]; then
      # Título en negrita
      printf '%s│%s  %s%s%s%s  %s│%s\n' \
        "$C_NEGRITA" "$C_RESET" \
        "$C_NEGRITA" "$texto" "$C_RESET" \
        "$relleno" \
        "$C_NEGRITA" "$C_RESET"
    else
      # Ítem normal
      printf '%s│%s  %s%s  %s│%s\n' \
        "$C_NEGRITA" "$C_RESET" \
        "$texto" "$relleno" \
        "$C_NEGRITA" "$C_RESET"
    fi
  done

  # 5) Borde inferior
  printf '%s└%s┘%s\n' "$C_NEGRITA" "$horizontal" "$C_RESET"
}

accion_estado() {
  if ! exigir_repo; then return; fi
  git status -sb
  printf '\n%sRemotos:%s\n' "$C_NEGRITA" "$C_RESET"
  if [[ -n "$(git remote)" ]]; then
    git remote -v
  else
    printf '  (ninguno)\n'
  fi
  printf '\n%sÚltimos commits:%s\n' "$C_NEGRITA" "$C_RESET"
  git --no-pager log --oneline -5 2>/dev/null || printf '  (sin commits)\n'
}

crear_gitignore() {
  if [[ -f ".gitignore" ]]; then
    info "Ya existe un .gitignore; no se modifica."
    return
  fi
  local lista=""
  local -a patrones=()
  read -rp "Patrones a ignorar [$ARCHIVOS_IGNORAR_POR_DEFECTO]: " lista || true
  lista="${lista:-$ARCHIVOS_IGNORAR_POR_DEFECTO}"
  read -ra patrones <<< "$lista"
  if [[ ${#patrones[@]} -eq 0 ]]; then
    warn "No se indicaron patrones; no se creó .gitignore."
    return
  fi
  {
    printf '# Archivos ignorados por Git (generado por admin_git.sh)\n'
    printf '%s\n' "${patrones[@]}"
  } > .gitignore
  ok "Archivo .gitignore creado con ${#patrones[@]} patrón(es)."
}

accion_init() {
  if es_repo; then
    warn "Ya hay un repositorio Git en $PWD."
    return
  fi
  if ! confirmar "¿Inicializar un repositorio Git aquí?"; then return; fi
  local rama=""
  read -rp "Rama inicial [$RAMA_PRINCIPAL]: " rama || true
  rama="${rama:-$RAMA_PRINCIPAL}"
  if ! git check-ref-format --branch "$rama" >/dev/null 2>&1; then
    warn "Nombre de rama inválido. Se usará '$RAMA_PRINCIPAL'."
    rama="$RAMA_PRINCIPAL"
  fi
  if ! git init >/dev/null 2>&1; then
    error "No se pudo inicializar el repositorio."
    return
  fi
  git symbolic-ref HEAD "refs/heads/$rama" 2>/dev/null || true
  ok "Repositorio inicializado (rama $rama)."
  crear_gitignore
  if confirmar "¿Configurar la identidad de Git ahora?"; then
    accion_identidad
  fi
  if confirmar "¿Integrar un repositorio remoto ahora?"; then
    accion_integrar
  fi
}

accion_identidad() {
  if ! exigir_repo; then return; fi
  local nombre=""
  local email=""
  local entrada=""
  local ambito=""
  nombre="$(git config user.name 2>/dev/null || true)"
  email="$(git config user.email 2>/dev/null || true)"
  printf 'Nombre actual: %s\n' "${nombre:-(sin configurar)}"
  printf 'Email actual : %s\n' "${email:-(sin configurar)}"
  read -rp "Nombre [$nombre]: " entrada || true
  nombre="${entrada:-$nombre}"
  entrada=""
  read -rp "Email [$email]: " entrada || true
  email="${entrada:-$email}"
  if [[ -z "$nombre" || -z "$email" ]]; then
    warn "El nombre y el email son obligatorios."
    return
  fi
  read -rp "Ámbito: 1) local 2) global [1]: " ambito || true
  if [[ "${ambito:-1}" == "2" ]]; then
    git config --global user.name "$nombre"
    git config --global user.email "$email"
    ok "Identidad global configurada."
  else
    git config user.name "$nombre"
    git config user.email "$email"
    ok "Identidad local configurada."
  fi
}

accion_commit() {
  if ! exigir_repo; then return; fi
  if ! identidad_ok; then
    warn "La identidad de Git no está configurada."
    if confirmar "¿Configurarla ahora?"; then
      accion_identidad
    else
      return
    fi
    if ! identidad_ok; then return; fi
  fi
  if ! hay_cambios; then
    info "No hay cambios para confirmar."
    return
  fi
  git status --short
  printf '\n'
  local rutas=""
  local mensaje=""
  local -a lista=()
  if confirmar "¿Preparar todos los cambios (git add -A)?"; then
    if ! git add -A; then
      error "No se pudieron preparar los cambios."
      return
    fi
  else
    read -rp "Rutas o archivos a preparar (separados por espacio): " rutas || true
    if [[ -z "$rutas" ]]; then
      warn "No se seleccionaron archivos."
      return
    fi
    read -ra lista <<< "$rutas"
    if ! git add -- "${lista[@]}"; then
      error "No se pudieron preparar los archivos."
      return
    fi
  fi
  if git diff --cached --quiet; then
    warn "No hay cambios preparados para confirmar."
    return
  fi
  read -rp "Mensaje de commit [$MENSAJE_COMMIT_POR_DEFECTO]: " mensaje || true
  mensaje="${mensaje:-$MENSAJE_COMMIT_POR_DEFECTO}"
  if git commit -m "$mensaje"; then
    ok "Commit creado."
    git --no-pager log -1 --oneline
  else
    error "No se pudo crear el commit."
  fi
}

ver_remotos() {
  if [[ -z "$(git remote)" ]]; then
    info "No hay remotos configurados."
    return
  fi
  git remote -v
}

remoto_manual() {
  local remoto=""
  local url=""
  remoto="$(pedir_remoto)"
  read -rp "URL del repositorio (HTTPS o SSH): " url || true
  if [[ -z "$url" ]]; then
    warn "La URL está vacía."
    return
  fi
  if git remote get-url "$remoto" >/dev/null 2>&1; then
    if confirmar "El remoto '$remoto' ya existe. ¿Actualizar su URL?"; then
      if git remote set-url "$remoto" "$url"; then
        ok "URL actualizada."
      else
        error "No se pudo actualizar la URL."
      fi
    else
      info "Sin cambios."
    fi
  else
    if git remote add "$remoto" "$url"; then
      ok "Remoto '$remoto' agregado."
    else
      error "No se pudo agregar el remoto."
    fi
  fi
}

cambiar_url_remoto() {
  local remoto=""
  local url=""
  if [[ -z "$(git remote)" ]]; then
    warn "No hay remotos configurados."
    return
  fi
  git remote -v
  read -rp "Remoto a modificar: " remoto || true
  if [[ -z "$remoto" ]] || ! git remote get-url "$remoto" >/dev/null 2>&1; then
    warn "Remoto inválido."
    return
  fi
  read -rp "Nueva URL: " url || true
  if [[ -z "$url" ]]; then
    warn "La URL está vacía."
    return
  fi
  if git remote set-url "$remoto" "$url"; then
    ok "URL actualizada."
  else
    error "No se pudo actualizar la URL."
  fi
}

eliminar_remoto() {
  local remoto=""
  if [[ -z "$(git remote)" ]]; then
    warn "No hay remotos configurados."
    return
  fi
  git remote -v
  read -rp "Remoto a eliminar: " remoto || true
  if [[ -z "$remoto" ]] || ! git remote get-url "$remoto" >/dev/null 2>&1; then
    warn "Remoto inválido."
    return
  fi
  if ! confirmar "¿Eliminar el remoto '$remoto'?"; then return; fi
  if git remote remove "$remoto"; then
    ok "Remoto eliminado."
  else
    error "No se pudo eliminar el remoto."
  fi
}

crear_repo_github() {
  if ! command -v gh >/dev/null 2>&1; then
    warn "GitHub CLI (gh) no está instalado. Use la opción manual o instale gh."
    return
  fi
  if ! gh auth status >/dev/null 2>&1; then
    warn "gh no está autenticado. Ejecute: gh auth login"
    return
  fi
  local remoto=""
  local nombre=""
  local entrada=""
  local vis=""
  remoto="$(pedir_remoto)"
  nombre="$(basename "$PWD")"
  read -rp "Nombre del repositorio [$nombre]: " entrada || true
  nombre="${entrada:-$nombre}"
  read -rp "Visibilidad (private/public) [$VISIBILIDAD_POR_DEFECTO]: " vis || true
  vis="${vis:-$VISIBILIDAD_POR_DEFECTO}"
  if [[ "$vis" != "private" && "$vis" != "public" ]]; then
    warn "Visibilidad inválida."
    return
  fi
  local -a args=("$nombre" "--$vis" --source=. --remote="$remoto")
  if git rev-parse --verify HEAD >/dev/null 2>&1; then
    args+=(--push)
  else
    warn "Aún no hay commits: el repositorio se creará sin push inicial."
  fi
  if ! confirmar "¿Crear '$nombre' en GitHub y configurar el remoto '$remoto'?"; then return; fi
  if gh repo create "${args[@]}"; then
    ok "Repositorio de GitHub creado."
  else
    error "No se pudo crear el repositorio. Puede configurarlo manualmente (opción 1)."
  fi
}

crear_repo_gitlab() {
  if ! command -v glab >/dev/null 2>&1; then
    warn "GitLab CLI (glab) no está instalado. Use la opción manual o instale glab."
    return
  fi
  if ! glab auth status >/dev/null 2>&1; then
    warn "glab no está autenticado. Ejecute: glab auth login"
    return
  fi
  local remoto=""
  local nombre=""
  local entrada=""
  local vis=""
  local ayuda=""
  remoto="$(pedir_remoto)"
  nombre="$(basename "$PWD")"
  read -rp "Nombre del repositorio [$nombre]: " entrada || true
  nombre="${entrada:-$nombre}"
  read -rp "Visibilidad (private/public) [$VISIBILIDAD_POR_DEFECTO]: " vis || true
  vis="${vis:-$VISIBILIDAD_POR_DEFECTO}"
  if [[ "$vis" != "private" && "$vis" != "public" ]]; then
    warn "Visibilidad inválida."
    return
  fi
  local -a args=("$nombre")
  if [[ "$vis" == "private" ]]; then
    args+=(--private)
  else
    args+=(--public)
  fi
  ayuda="$(glab repo create --help 2>&1 || true)"
  if grep -q -- '--source' <<< "$ayuda"; then
    args+=(--source=.)
  fi
  if grep -q -- '--remote' <<< "$ayuda"; then
    args+=(--remote "$remoto")
  fi
  if grep -q -- '--push' <<< "$ayuda" && git rev-parse --verify HEAD >/dev/null 2>&1; then
    args+=(--push)
  fi
  if ! confirmar "¿Crear '$nombre' en GitLab y configurar el remoto '$remoto'?"; then return; fi
  if glab repo create "${args[@]}"; then
    ok "Repositorio de GitLab creado."
    if ! git remote get-url "$remoto" >/dev/null 2>&1; then
      warn "No se detectó el remoto '$remoto'. Verifique con la opción 4."
    fi
  else
    error "No se pudo crear el repositorio. Puede configurarlo manualmente (opción 1)."
  fi
}

abrir_remoto_web() {
  local remoto=""
  local url=""
  remoto="$(remoto_efectivo)" || {
    warn "No hay remoto configurado."
    return
  }
  url="$(git remote get-url "$remoto" 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    warn "No se pudo obtener la URL del remoto."
    return
  fi
  case "$url" in
    git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
    git@gitlab.com:*) url="https://gitlab.com/${url#git@gitlab.com:}" ;;
    ssh://git@github.com/*) url="https://github.com/${url#ssh://git@github.com/}" ;;
    ssh://git@gitlab.com/*) url="https://gitlab.com/${url#ssh://git@gitlab.com/}" ;;
    https://*|http://*) ;;
    *)
      warn "No se reconoce el formato de la URL: $url"
      return
      ;;
  esac
  url="${url%.git}"
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$url" >/dev/null 2>&1 &
    ok "Abriendo $url"
  else
    info "$url"
  fi
}

accion_integrar() {
  if ! exigir_repo; then return; fi
  local opcion=""
  while true; do
    printf '\n%s--- Integrar repositorio remoto ---%s\n' "$C_NEGRITA" "$C_RESET"
    printf '  1) Configurar remoto manualmente (URL)\n'
    printf '  2) Crear repositorio en GitHub (gh)\n'
    printf '  3) Crear repositorio en GitLab (glab)\n'
    printf '  4) Ver remotos\n'
    printf '  5) Cambiar URL de un remoto\n'
    printf '  6) Eliminar un remoto\n'
    printf '  7) Abrir repositorio en el navegador\n'
    printf '  0) Volver\n'
    read -rp "Opción: " opcion || return
    case "$opcion" in
      1) remoto_manual ;;
      2) crear_repo_github ;;
      3) crear_repo_gitlab ;;
      4) ver_remotos ;;
      5) cambiar_url_remoto ;;
      6) eliminar_remoto ;;
      7) abrir_remoto_web ;;
      0|"") return ;;
      *) warn "Opción no válida." ;;
    esac
  done
}

accion_push() {
  if ! exigir_repo; then return; fi
  local remoto=""
  local rama=""
  local upstream=""
  local forzar=""
  local respuesta=""
  remoto="$(remoto_efectivo)" || {
    warn "No hay remoto configurado."
    if confirmar "¿Configurarlo ahora?"; then
      accion_integrar
    fi
    return
  }
  rama="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [[ -z "$rama" ]]; then
    warn "No está en una rama (HEAD desacoplado)."
    return
  fi
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    warn "Aún no hay commits para subir."
    return
  fi
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  read -rp "¿Usar push forzado seguro (--force-with-lease)? [s/N]: " respuesta || true
  if [[ "$respuesta" =~ ^[SsYy]$ ]]; then
    forzar="--force-with-lease"
  fi
  local -a args=(push)
  if [[ -n "$forzar" ]]; then
    args+=("$forzar")
  fi
  if [[ -z "$upstream" ]]; then
    if ! confirmar "La rama '$rama' no tiene upstream. ¿Subirla a '$remoto/$rama'?"; then return; fi
    args+=(-u "$remoto" "$rama")
  else
    args+=("$remoto" "$rama")
  fi
  if git "${args[@]}"; then
    ok "Push completado."
  else
    warn "El push no se completó. Revise el estado o haga Pull primero."
  fi
}

accion_pull() {
  if ! exigir_repo; then return; fi
  local remoto=""
  local rama=""
  local estrategia=""
  local resultado=1
  remoto="$(remoto_efectivo)" || {
    warn "No hay remoto configurado."
    return
  }
  rama="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [[ -z "$rama" ]]; then
    warn "No está en una rama (HEAD desacoplado)."
    return
  fi
  if hay_cambios; then
    warn "Hay cambios locales sin confirmar."
    if confirmar "¿Guardarlos en stash antes del pull?"; then
      accion_stash_guardar
      info "Recuerde recuperar sus cambios con la opción 13 (stash)."
    else
      if ! confirmar "¿Continuar con el pull de todos modos?"; then return; fi
    fi
  fi
  if ! git fetch "$remoto" --prune; then
    error "No se pudo consultar el remoto."
    return
  fi
  if ! git show-ref --verify --quiet "refs/remotes/$remoto/$rama"; then
    warn "La rama '$remoto/$rama' no existe. Haga push primero."
    return
  fi
  printf 'Estrategia de pull:\n'
  printf '  1) Solo fast-forward (recomendado)\n'
  printf '  2) Rebase\n'
  printf '  3) Merge\n'
  read -rp "Opción [1]: " estrategia || true
  case "${estrategia:-1}" in
    1) git pull --ff-only "$remoto" "$rama"; resultado=$? ;;
    2) git pull --rebase "$remoto" "$rama"; resultado=$? ;;
    3) git pull --no-rebase "$remoto" "$rama"; resultado=$? ;;
    *)
      warn "Opción no válida."
      return
      ;;
  esac
  if [[ $resultado -ne 0 ]]; then
    warn "El pull no se completó. Revise conflictos o el estado del repositorio."
    return
  fi
  ok "Pull completado."
  if [[ -z "$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)" ]]; then
    if confirmar "¿Establecer '$remoto/$rama' como upstream de '$rama'?"; then
      if git branch --set-upstream-to="$remoto/$rama" "$rama" >/dev/null; then
        ok "Upstream configurado."
      fi
    fi
  fi
}

comparar_ramas() {
  local rama1=""
  local rama2=""
  local entrada=""
  rama1="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  rama2="$RAMA_PRINCIPAL"
  if git show-ref --verify --quiet "refs/remotes/$REMOTO_POR_DEFECTO/$RAMA_PRINCIPAL"; then
    rama2="$REMOTO_POR_DEFECTO/$RAMA_PRINCIPAL"
  fi
  read -rp "Rama origen [$rama1]: " entrada || true
  rama1="${entrada:-$rama1}"
  entrada=""
  read -rp "Rama destino [$rama2]: " entrada || true
  rama2="${entrada:-$rama2}"
  if [[ -z "$rama1" || -z "$rama2" ]]; then
    warn "Debe indicar ambas ramas."
    return
  fi
  if ! git rev-parse --verify "$rama1" >/dev/null 2>&1; then
    warn "No existe la rama '$rama1'."
    return
  fi
  if ! git rev-parse --verify "$rama2" >/dev/null 2>&1; then
    warn "No existe la rama '$rama2'."
    return
  fi
  paginar git --no-pager diff --stat --color=always "$rama1"..."$rama2"
  if confirmar "¿Ver el diff completo?"; then
    ver_diff "$rama1"..."$rama2"
  fi
}

accion_diff() {
  if ! exigir_repo; then return; fi
  local opcion=""
  while true; do
    printf '\n%s--- Diferencias ---%s\n' "$C_NEGRITA" "$C_RESET"
    printf '  1) Cambios sin preparar\n'
    printf '  2) Cambios preparados (staged)\n'
    printf '  3) Todos los cambios contra HEAD\n'
    printf '  4) Comparar dos ramas\n'
    printf '  5) Resumen del último commit\n'
    printf '  6) Contenido del último commit\n'
    printf '  0) Volver\n'
    read -rp "Opción: " opcion || return
    case "$opcion" in
      1) ver_diff ;;
      2) ver_diff --cached ;;
      3)
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
          ver_diff HEAD
        else
          warn "Aún no hay commits."
        fi
        ;;
      4) comparar_ramas ;;
      5)
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
          paginar git --no-pager show --stat --color=always HEAD
        else
          warn "Aún no hay commits."
        fi
        ;;
      6)
        if git rev-parse --verify HEAD >/dev/null 2>&1; then
          ver_show HEAD
        else
          warn "Aún no hay commits."
        fi
        ;;
      0|"") return ;;
      *) warn "Opción no válida." ;;
    esac
  done
}

accion_cambiar_rama() {
  if ! exigir_repo; then return; fi
  local -a ramas=()
  local i=0
  local seleccion=""
  local rama=""
  local actual=""
  local remoto=""
  actual="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  mapfile -t ramas < <(git for-each-ref --format='%(refname:short)' refs/heads | sort)
  if [[ ${#ramas[@]} -eq 0 ]]; then
    warn "No hay ramas locales."
    return
  fi
  printf '%sRamas locales:%s\n' "$C_NEGRITA" "$C_RESET"
  for i in "${!ramas[@]}"; do
    if [[ "${ramas[$i]}" == "$actual" ]]; then
      printf '  %2d) %s (actual)\n' "$((i+1))" "${ramas[$i]}"
    else
      printf '  %2d) %s\n' "$((i+1))" "${ramas[$i]}"
    fi
  done
  read -rp "Número o nombre de rama (Enter para cancelar): " seleccion || true
  if [[ -z "$seleccion" ]]; then return; fi
  if [[ "$seleccion" =~ ^[0-9]+$ ]]; then
    if (( seleccion >= 1 && seleccion <= ${#ramas[@]} )); then
      rama="${ramas[$((seleccion-1))]}"
    else
      warn "Número inválido."
      return
    fi
  else
    rama="$seleccion"
  fi
  if [[ "$rama" == "$actual" ]]; then
    info "Ya está en la rama '$rama'."
    return
  fi
  if ! git show-ref --verify --quiet "refs/heads/$rama"; then
    remoto="$(remoto_efectivo 2>/dev/null || true)"
    if [[ -n "$remoto" ]] && git show-ref --verify --quiet "refs/remotes/$remoto/$rama"; then
      if confirmar "La rama '$rama' no existe localmente. ¿Crearla desde '$remoto/$rama'?"; then
        if git switch -c "$rama" --track "$remoto/$rama" 2>/dev/null; then
          ok "Rama '$rama' creada y activa."
        else
          git checkout -b "$rama" --track "$remoto/$rama"
        fi
        return
      fi
    fi
    warn "La rama '$rama' no existe."
    return
  fi
  if hay_cambios; then
    warn "Hay cambios locales sin confirmar."
    if confirmar "¿Guardarlos en stash antes de cambiar?"; then
      accion_stash_guardar
    else
      if ! confirmar "¿Cambiar de todos modos?"; then return; fi
    fi
  fi
  if git switch "$rama" 2>/dev/null; then
    ok "Ahora está en la rama '$rama'."
  else
    if git checkout "$rama"; then
      ok "Ahora está en la rama '$rama'."
    fi
  fi
}

accion_crear_rama() {
  if ! exigir_repo; then return; fi
  local rama=""
  read -rp "Nombre de la nueva rama: " rama || true
  if [[ -z "$rama" ]]; then return; fi
  if ! git check-ref-format --branch "$rama" >/dev/null 2>&1; then
    warn "Nombre de rama inválido."
    return
  fi
  if git show-ref --verify --quiet "refs/heads/$rama"; then
    warn "La rama '$rama' ya existe."
    return
  fi
  if git switch -c "$rama" 2>/dev/null; then
    ok "Rama '$rama' creada y activa."
  else
    if git checkout -b "$rama"; then
      ok "Rama '$rama' creada y activa."
    else
      error "No se pudo crear la rama."
    fi
  fi
}

accion_fusionar() {
  if ! exigir_repo; then return; fi
  local actual=""
  local origen=""
  local rama=""
  actual="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
  if [[ -z "$actual" ]]; then
    warn "No está en una rama."
    return
  fi
  printf '%sRama actual: %s%s\n' "$C_NEGRITA" "$actual" "$C_RESET"
  printf 'Ramas disponibles:\n'
  while IFS= read -r rama; do
    [[ "$rama" == "$actual" ]] && continue
    printf '  %s\n' "$rama"
  done < <(git for-each-ref --format='%(refname:short)' refs/heads | sort)
  read -rp "Rama a fusionar en '$actual': " origen || true
  if [[ -z "$origen" ]]; then return; fi
  if ! git show-ref --verify --quiet "refs/heads/$origen"; then
    warn "No existe la rama '$origen'."
    return
  fi
  if ! confirmar "¿Fusionar '$origen' en '$actual'?"; then return; fi
  if git merge "$origen"; then
    ok "Fusión completada."
  else
    warn "La fusión requiere resolver conflictos."
  fi
}

accion_fetch() {
  if ! exigir_repo; then return; fi
  if ! remoto_efectivo >/dev/null; then
    warn "No hay remoto configurado."
    return
  fi
  if git fetch --all --prune; then
    ok "Referencias remotas actualizadas."
  else
    error "No se pudieron actualizar las referencias remotas."
  fi
}

accion_log() {
  if ! exigir_repo; then return; fi
  if ! git rev-parse --verify HEAD >/dev/null 2>&1; then
    warn "Aún no hay commits."
    return
  fi
  paginar git --no-pager log --oneline --graph --decorate --all --color=always -n 40
}

accion_stash_guardar() {
  if ! exigir_repo; then return; fi
  if ! hay_cambios; then
    info "No hay cambios para guardar."
    return
  fi
  local mensaje=""
  local incluir=""
  read -rp "Descripción del stash [stash $(date '+%Y%m%d-%H%M%S')]: " mensaje || true
  mensaje="${mensaje:-stash $(date '+%Y%m%d-%H%M%S')}"
  read -rp "¿Incluir archivos no rastreados? [S/n]: " incluir || true
  if [[ -z "$incluir" || "$incluir" =~ ^[SsYy]$ ]]; then
    if git stash push -u -m "$mensaje" 2>/dev/null; then
      ok "Cambios guardados en stash."
    elif git stash save -u "$mensaje"; then
      ok "Cambios guardados en stash."
    else
      error "No se pudo guardar el stash."
    fi
  else
    if git stash push -m "$mensaje" 2>/dev/null; then
      ok "Cambios guardados en stash."
    elif git stash save "$mensaje"; then
      ok "Cambios guardados en stash."
    else
      error "No se pudo guardar el stash."
    fi
  fi
}

accion_stash() {
  if ! exigir_repo; then return; fi
  local opcion=""
  local indice=""
  local ref=""
  while true; do
    printf '\n%s--- Stash ---%s\n' "$C_NEGRITA" "$C_RESET"
    printf '  1) Guardar cambios\n'
    printf '  2) Listar stashes\n'
    printf '  3) Aplicar un stash (conservarlo)\n'
    printf '  4) Aplicar y eliminar un stash (pop)\n'
    printf '  5) Eliminar un stash\n'
    printf '  0) Volver\n'
    read -rp "Opción: " opcion || return
    case "$opcion" in
      1) accion_stash_guardar ;;
      2) git stash list ;;
      3)
        if [[ -z "$(git stash list)" ]]; then
          info "No hay stashes."
        else
          git stash list
          indice=""
          read -rp "Índice del stash [0]: " indice || true
          ref="stash@{${indice:-0}}"
          git stash apply "$ref"
        fi
        ;;
      4)
        if [[ -z "$(git stash list)" ]]; then
          info "No hay stashes."
        else
          git stash list
          indice=""
          read -rp "Índice del stash [0]: " indice || true
          ref="stash@{${indice:-0}}"
          git stash pop "$ref"
        fi
        ;;
      5)
        if [[ -z "$(git stash list)" ]]; then
          info "No hay stashes."
        else
          git stash list
          indice=""
          read -rp "Índice del stash [0]: " indice || true
          ref="stash@{${indice:-0}}"
          if confirmar "¿Eliminar el stash '$ref'?"; then
            git stash drop "$ref"
          fi
        fi
        ;;
      0|"") return ;;
      *) warn "Opción no válida." ;;
    esac
  done
}

accion_descartar() {
  if ! exigir_repo; then return; fi
  if ! hay_cambios; then
    info "No hay cambios locales."
    return
  fi
  local opcion=""
  git status --short
  printf '\n%s--- Descartar cambios ---%s\n' "$C_NEGRITA" "$C_RESET"
  printf '  1) Descartar cambios en archivos rastreados\n'
  printf '  2) Eliminar archivos no rastreados\n'
  printf '  3) Ambas acciones\n'
  printf '  0) Cancelar\n'
  read -rp "Opción: " opcion || return
  case "$opcion" in
    1|2|3) ;;
    *)
      info "Cancelado."
      return
      ;;
  esac
  if ! confirmar_texto "DESCARTAR" "Esta acción es irreversible. Escriba DESCARTAR para confirmar:"; then
    info "Cancelado."
    return
  fi
  if [[ "$opcion" == "1" || "$opcion" == "3" ]]; then
    if git rev-parse --verify HEAD >/dev/null 2>&1; then
      if ! git restore --source=HEAD --staged --worktree . 2>/dev/null; then
        git reset --hard HEAD
      fi
      ok "Cambios en archivos rastreados descartados."
    else
      warn "No hay commit inicial; no se pueden restaurar los archivos rastreados."
    fi
  fi
  if [[ "$opcion" == "2" || "$opcion" == "3" ]]; then
    if git clean -fd; then
      ok "Archivos no rastreados eliminados."
    else
      error "No se pudieron eliminar los archivos no rastreados."
    fi
  fi
}

# =============================================================================
# UTILIDADES DEL SISTEMA (nuevas)
# =============================================================================

accion_shell() {
  # Abre un shell interactivo en el directorio actual. Al salir ("exit"),
  # el control vuelve al menú principal.
  local shell="${SHELL:-/bin/bash}"
  if ! command -v "$shell" >/dev/null 2>&1; then
    error "No se encontró el shell '$shell'."
    return
  fi
  info "Abriendo '$shell' en $PWD. Escriba 'exit' para volver al menú."
  # Sin `exec` para que al salir se retome el script. Sin `-i` explícito:
  # si stdin es una tty (lo es, estamos en el menú) el shell será interactivo.
  "$shell" || warn "El shell terminó con código $?."
  ok "De vuelta al menú."
}

seleccionar_archivo_fzf() {
  # Navegador interactivo de archivos con fdfind + fzf.
  # Lista los subdirectorios y archivos del directorio actual, más la entrada
  # "../" para subir al directorio padre. Al elegir un subdirectorio se entra
  # en él y se refresca la lista; al elegir un archivo se selecciona.
  # Imprime por stdout la ruta ABSOLUTA del archivo elegido. Si se cancela
  # con ESC (o sin selección), no imprime nada y devuelve 1.
  local origen="$PWD"
  local sel=""
  local abs=""
  local e=""
  local -a items=()

  while true; do
    items=("../")

    # Directorios del nivel actual (fdfind los muestra con '/' final).
    # --no-ignore: muestra también rutas ignoradas por .gitignore/.ignore
    #              (p. ej. bin/, obj/, node_modules/).
    # --follow:    sigue enlaces simbólicos y los muestra como directorios.
    while IFS= read -r e; do
      [[ -n "$e" ]] && items+=("$e")
    done < <(fdfind --type d --hidden --exclude .git --no-ignore --follow --max-depth 1 2>/dev/null | sort)

    # Archivos del nivel actual.
    while IFS= read -r e; do
      [[ -n "$e" ]] && items+=("$e")
    done < <(fdfind --type f --hidden --exclude .git --no-ignore --follow --max-depth 1 2>/dev/null | sort)

    sel="$(
      printf '%s\n' "${items[@]}" \
        | fzf --height 90% --reverse \
              --prompt "Archivo> ${PWD} > " \
              --preview 'if [ -d {} ]; then ls -la -- {}; else head -n 100 -- {} 2>/dev/null; fi' \
              --preview-window 'right:60%'
    )" || true

    if [[ -z "$sel" ]]; then
      # ESC o sin selección: cancelar.
      cd -- "$origen" 2>/dev/null || true
      return 1
    fi

    case "$sel" in
      */)
        # Subdirectorio o "../": entrar/salir de carpeta y volver a listar.
        cd -- "${sel%/}" 2>/dev/null || true
        ;;
      *)
        # Archivo elegido: calcular ruta absoluta y restaurar el directorio.
        abs="${PWD%/}/$sel"
        cd -- "$origen" 2>/dev/null || true
        printf '%s' "$abs"
        return 0
        ;;
    esac
  done
}

accion_editar_vi() {
  local archivo=""
  local editor="vi"

  if ! command -v "$editor" >/dev/null 2>&1; then
    error "'$editor' no está instalado."
    return
  fi

  # Selección interactiva del archivo con fdfind + fzf.
  # Permite navegar entre carpetas: elegir un subdirectorio para entrar y
  # "../" para subir al directorio padre. ESC cancela la selección.
  if command -v fzf >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    if ! archivo="$(seleccionar_archivo_fzf)"; then
      info "Cancelado."
      return
    fi
  else
    # Respaldo si fzf/fdfind no están instalados: entrada manual.
    warn "fzf y/o fdfind no están instalados; se usará entrada manual."
    read -rp "Archivo a editar (Enter para cancelar): " archivo || true
    if [[ -z "$archivo" ]]; then
      info "Cancelado."
      return
    fi
  fi

  # Expandir ~ al inicio
  archivo="${archivo/#\~/$HOME}"

  # Aviso si el archivo no existe (vi lo crea, pero conviene saberlo)
  if [[ ! -e "$archivo" ]]; then
    warn "El archivo no existe. vi lo creará al guardar."
    if ! confirmar "¿Continuar?"; then return; fi
  fi

  info "Editando '$archivo' con $editor..."
  "$editor" "$archivo" || warn "El editor terminó con código $?."
  if [[ -e "$archivo" ]]; then
    ok "Edición finalizada: $archivo"
  fi
}

accion_mc() {
  if ! command -v mc >/dev/null 2>&1; then
    error "Midnight Commander (mc) no está instalado."
    info "Instálelo con: sudo apt install mc   (Debian/Ubuntu)  o  sudo dnf install mc   (Fedora)."
    return
  fi
  info "Abriendo Midnight Commander en $PWD..."
  mc || warn "mc terminó con código $?."
  ok "De vuelta al menú."
}

main() {
  requiere_git
  local opcion=""
  while true; do
    mostrar_cabecera
    mostrar_menu
    opcion=""
    read -rp "Opción: " opcion || {
      printf '\n'
      exit 0
    }
    case "$opcion" in
      1) accion_estado ;;
      2) accion_init ;;
      3) accion_commit ;;
      4) accion_integrar ;;
      5) accion_push ;;
      6) accion_pull ;;
      7) accion_diff ;;
      8) accion_cambiar_rama ;;
      9) accion_crear_rama ;;
      10) accion_fusionar ;;
      11) accion_fetch ;;
      12) accion_log ;;
      13) accion_stash ;;
      14) accion_descartar ;;
      15) accion_identidad ;;
      16) accion_shell ;;
      17) accion_editar_vi ;;
      18) accion_mc ;;
      0|q|Q)
        ok "Hasta luego."
        exit 0
        ;;
      *) warn "Opción no válida." ;;
    esac
    pausa
  done
}

main "$@"