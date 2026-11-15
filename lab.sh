#!/usr/bin/env bash
# FIT Lab Wazuh - administracion segura del laboratorio Docker Compose
# Solo administra recursos del proyecto fit_lab_wazuh_dock.
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
PROJECT="fit_lab_wazuh_dock"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.lab.yml)
CERT_COMPOSE=(docker compose -p "${PROJECT}_certs" -f generate-indexer-certs.yml)
CERT_DIR="$ROOT_DIR/config/wazuh_indexer_ssl_certs"
CERT_FILES=(root-ca.pem root-ca-manager.pem admin.pem admin-key.pem wazuh.indexer.pem wazuh.indexer-key.pem wazuh.manager.pem wazuh.manager-key.pem wazuh.dashboard.pem wazuh.dashboard-key.pem)
STATE_DIR="$ROOT_DIR/.lab-state"
KEY_BACKUP="$STATE_DIR/victim01.client.keys"
MANAGER_WAIT=300
AGENT_WAIT=180
ACTION="${1:-}"

say()  { printf '\n[LAB] %s\n' "$*"; }
warn() { printf '\n[AVISO] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_tools() {
  command -v docker >/dev/null || fail 'Docker no esta instalado.'
  command -v sysctl >/dev/null || fail 'No se encuentra sysctl.'
  docker compose version >/dev/null 2>&1 || fail 'Se necesita Docker Compose v2.'
  docker info >/dev/null 2>&1 || fail "Sin acceso a Docker. Ejecuta: sudo ./lab.sh $ACTION"
  [[ -f docker-compose.yml && -f docker-compose.lab.yml && -f generate-indexer-certs.yml && -f config/certs.yml ]] || fail "Faltan archivos del proyecto en $ROOT_DIR."
}

validate_compose() {
  "${COMPOSE[@]}" config --quiet || fail 'Configuracion Compose invalida.'
  "${CERT_COMPOSE[@]}" config --quiet || fail 'Configuracion Compose de certificados invalida.'
}

protect_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  # Excluir copias privadas aunque el usuario olvide actualizar .gitignore.
  if [[ -d .git ]]; then
    mkdir -p .git/info
    if [[ ! -f .git/info/exclude ]] || ! grep -Fxq '/.lab-state/' .git/info/exclude; then
      printf '\n/.lab-state/\n' >> .git/info/exclude
    fi
  fi
}

ensure_map_count() {
  local current
  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if (( current < 262144 )); then
    say 'Ajustando vm.max_map_count=262144 (temporal hasta reinicio del host).'
    sysctl -w vm.max_map_count=262144 >/dev/null || fail 'No se pudo ajustar vm.max_map_count.'
  fi
}

missing_certs() {
  local file
  for file in "${CERT_FILES[@]}"; do
    [[ -s "$CERT_DIR/$file" ]] || return 0
  done
  return 1
}

ensure_certs() {
  if ! missing_certs; then
    say 'Certificados completos; se conservaran.'
    return
  fi
  mkdir -p "$CERT_DIR"
  if find "$CERT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
    fail "Hay certificados parciales en $CERT_DIR; revisar manualmente, no se sobreescribiran."
  fi
  say 'Generando certificados por primera vez...'
  "${CERT_COMPOSE[@]}" run --rm generator
  missing_certs && fail 'Generador finalizo sin todos los certificados necesarios.'
}

service_id() { "${COMPOSE[@]}" ps -a -q "$1"; }
manager_id() { service_id wazuh.manager; }
victim_id() { service_id victim01; }

running_id() {
  local cid
  cid="$(service_id "$1" 2>/dev/null || true)"
  [[ -n "$cid" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null || true)" == true ]]
}

wait_manager() {
  local cid elapsed status=''
  cid="$(manager_id)"
  [[ -n "$cid" ]] || fail 'No existe el contenedor Wazuh Manager.'
  say "Esperando db, remoted y authd (maximo ${MANAGER_WAIT}s)..."
  for ((elapsed=0; elapsed<MANAGER_WAIT; elapsed+=5)); do
    status="$(docker exec "$cid" /var/ossec/bin/wazuh-control status 2>/dev/null || true)"
    if [[ "$status" == *'wazuh-db is running'* &&
          "$status" == *'wazuh-remoted is running'* &&
          "$status" == *'wazuh-authd is running'* ]]; then
      say 'Manager preparado.'
      return 0
    fi
    sleep 5
  done
  warn "Estado final del Manager:\n$status"
  "${COMPOSE[@]}" logs --tail 40 wazuh.manager >&2 || true
  fail 'Manager sin disponibilidad confirmada: no se iniciara victim01.'
}

agents_text() {
  local cid
  cid="$(manager_id)"
  [[ -n "$cid" ]] || return 1
  docker exec "$cid" /var/ossec/bin/agent_control -l
}

victim_agent_line() {
  local listing="$1"
  printf '%s\n' "$listing" | grep -E '^ *ID: [0-9]+, Name: victim01, ' | head -n 1 || true
}

victim_agent_id() {
  local line
  line="$(victim_agent_line "$1")"
  [[ -n "$line" ]] || return 1
  sed -nE 's/^ *ID: ([0-9]+), Name: victim01,.*/\1/p' <<< "$line"
}

backup_agent_key() {
  local cid tempfile key_id existing_list registered_id
  cid="$(victim_id)"
  [[ -n "$cid" ]] || return 1
  protect_state
  tempfile="$(mktemp "$STATE_DIR/.client.keys.XXXXXX")"
  if ! docker cp "$cid:/var/ossec/etc/client.keys" "$tempfile" >/dev/null 2>&1 || [[ ! -s "$tempfile" ]]; then
    rm -f "$tempfile"
    return 1
  fi
  key_id="$(awk '$2=="victim01" {print $1; exit}' "$tempfile")"
  if [[ -z "$key_id" ]]; then
    rm -f "$tempfile"
    return 1
  fi
  # Un archivo de identidad solo es seguro para restaurar si el Manager conoce ese ID.
  existing_list="$(agents_text 2>/dev/null || true)"
  registered_id="$(victim_agent_id "$existing_list" || true)"
  if [[ -z "$registered_id" ]] || [[ "$((10#$key_id))" -ne "$((10#$registered_id))" ]]; then
    rm -f "$tempfile"
    warn 'La identidad local no coincide con la registrada en Manager; no se hara copia.'
    return 1
  fi
  mv -f "$tempfile" "$KEY_BACKUP"
  chmod 600 "$KEY_BACKUP"
  say "Identidad del agente $registered_id guardada en .lab-state (archivo privado)."
}

backup_is_valid() {
  local manager_listing="$1" registered_id backed_id
  [[ -s "$KEY_BACKUP" ]] || return 1
  registered_id="$(victim_agent_id "$manager_listing" || true)"
  backed_id="$(awk '$2=="victim01" {print $1; exit}' "$KEY_BACKUP")"
  [[ "$registered_id" =~ ^[0-9]+$ && "$backed_id" =~ ^[0-9]+$ ]] || return 1
  (( 10#$registered_id == 10#$backed_id ))
}

restore_key_if_needed() {
  local cid current_key listing line temp_key
  cid="$(victim_id)"
  [[ -n "$cid" ]] || fail 'No existe el contenedor victim01 para restaurar identidad.'
  listing="$(agents_text)" || fail 'No fue posible consultar el registro de agentes.'
  line="$(victim_agent_line "$listing")"
  if [[ -z "$line" ]]; then
    # El Manager empieza vacio: nueva identidad por enrolamiento normal.
    [[ ! -s "$KEY_BACKUP" ]] || warn 'Hay una clave antigua en .lab-state; no se utilizara porque Manager no tiene registro.'
    return 0
  fi
  protect_state
  temp_key="$(mktemp "$STATE_DIR/.check-key.XXXXXX")"
  if docker cp "$cid:/var/ossec/etc/client.keys" "$temp_key" >/dev/null 2>&1; then
    current_key="$(awk '$2=="victim01" {print $1; exit}' "$temp_key")"
  else
    current_key=''
  fi
  rm -f "$temp_key"
  if [[ -n "$current_key" ]] && [[ "$((10#$current_key))" -eq "$((10#$(victim_agent_id "$listing")))" ]]; then
    say 'victim01 conserva su clave de agente registrada.'
    return 0
  fi
  if ! backup_is_valid "$listing"; then
    fail 'Manager conserva victim01, pero el contenedor no tiene clave valida y no existe respaldo coincidente. No se borrara ni registrara un duplicado. Usa un respaldo valido o reset --yes (destructivo).'
  fi
  docker cp "$KEY_BACKUP" "$cid:/var/ossec/etc/client.keys"
  # El respaldo se conserva con modo 0600; docker cp funciona tambien con el contenedor detenido.
  say 'Identidad registrada restaurada en victim01 ANTES de arrancarlo.'
}

wait_agent() {
  local elapsed listing line
  say "Esperando agente victim01 Active (maximo ${AGENT_WAIT}s)..."
  for ((elapsed=0; elapsed<AGENT_WAIT; elapsed+=5)); do
    listing="$(agents_text 2>/dev/null || true)"
    line="$(victim_agent_line "$listing")"
    if [[ -n "$line" && "$line" == *'Active'* ]]; then
      say "Agente conectado: $line"
      backup_agent_key || warn 'Agente activo, pero no se pudo proteger client.keys; evita rebuild hasta corregirlo.'
      return 0
    fi
    sleep 5
  done
  warn 'El agente no llego a Active. Estado y ultimos eventos:'
  agents_text >&2 || true
  docker logs --tail 45 victim01 >&2 || true
  return 1
}

start_victim() {
  local cid
  cid="$(victim_id)"
  if [[ -n "$cid" ]] && running_id victim01; then
    say 'victim01 ya esta iniciado.'
  else
    if [[ -z "$cid" ]]; then
      say 'Creando victim01 DETENIDO para validar/restaurar identidad antes de arrancar...'
      "${COMPOSE[@]}" create --no-deps victim01
    fi
    restore_key_if_needed
    "${COMPOSE[@]}" start victim01
  fi
  wait_agent || fail 'victim01 no esta Active. No se eliminara ningun agente automaticamente.'
}

start_lab() {
  ensure_map_count
  validate_compose
  ensure_certs
  protect_state
  say 'Iniciando primero Indexer, Manager, Dashboard y atacante...'
  "${COMPOSE[@]}" up -d wazuh.indexer wazuh.manager wazuh.dashboard attacker01
  wait_manager
  start_victim
  "${COMPOSE[@]}" ps -a
  say 'Laboratorio listo: https://localhost'
}

reset_lab() {
  [[ "${2:-}" == '--yes' ]] || fail 'Destructivo: usar sudo ./lab.sh reset --yes'
  validate_compose
  say 'RESET DESTRUCTIVO: se borran contenedores, volumenes, registros de agentes, alertas y clave local protegida.'
  "${COMPOSE[@]}" down --volumes --remove-orphans
  local leftovers
  leftovers="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")"
  [[ -z "$leftovers" ]] || fail "Persisten volumenes etiquetados del proyecto:\n$leftovers"
  # Borrar la copia local solo cuando Compose down --volumes termino correctamente.
  rm -f "$KEY_BACKUP"
  say 'Reconstruyendo imagenes personalizadas sin cache...'
  "${COMPOSE[@]}" build --no-cache --pull victim01 attacker01
  ensure_map_count
  ensure_certs
  say 'Arrancando los componentes centrales SIN victim01...'
  "${COMPOSE[@]}" up -d wazuh.indexer wazuh.manager wazuh.dashboard attacker01
  wait_manager
  local listing
  listing="$(agents_text)" || fail 'No fue posible consultar los agentes del Manager.'
  if printf '%s\n' "$listing" | grep -Eq '^ *ID: ([1-9][0-9]*|0*[1-9][0-9]*), Name:'; then
    printf '%s\n' "$listing" >&2
    fail 'RESET NO LIMPIO: hay un agente registrado antes de iniciar victim01. Verifica volumenes o bind mounts.'
  fi
  say 'Manager limpio: solo registro local 000. Iniciando primera victima...'
  start_victim
  listing="$(agents_text)"
  if printf '%s\n' "$listing" | grep -Eq '^ *ID: 001, Name: victim01, .*Active'; then
    say 'CONFIRMADO: victim01 es 001 y esta Active.'
  else
    printf '%s\n' "$listing" >&2
    fail 'victim01 no aparecio como 001 Active.'
  fi
}

rebuild_lab() {
  validate_compose
  wait_manager
  if [[ -n "$(victim_id)" ]]; then
    backup_agent_key || fail 'No se pudo conservar client.keys; cancelando rebuild para evitar Duplicate agent name.'
  else
    local listing
    listing="$(agents_text)"
    if [[ -n "$(victim_agent_line "$listing")" ]] && ! backup_is_valid "$listing"; then
      fail 'Existe victim01 en Manager sin clave respaldada. Se cancela rebuild.'
    fi
  fi
  say 'Reconstruyendo las dos imagenes personalizadas...'
  "${COMPOSE[@]}" build --no-cache --pull victim01 attacker01
  # Quitar solo los contenedores de laboratorio; no alterar Manager/Indexer/Dashboard.
  "${COMPOSE[@]}" stop victim01 attacker01 || true
  "${COMPOSE[@]}" rm -sf victim01 attacker01
  "${COMPOSE[@]}" up -d --no-deps attacker01
  start_victim
  say 'Rebuild completado sin registrar una nueva identidad.'
}

stop_lab() {
  if running_id victim01; then
    backup_agent_key || warn 'No se pudo copiar client.keys antes de detener.'
  fi
  "${COMPOSE[@]}" stop
  say 'Servicios detenidos; datos y volumenes intactos.'
}

status_lab() {
  "${COMPOSE[@]}" ps -a
  say 'Agentes registrados:'
  agents_text || true
  if [[ -s "$KEY_BACKUP" ]]; then
    say 'Existe copia protegida de la identidad de victim01 (.lab-state).'
  else
    warn 'No existe copia local de client.keys. Se guardara cuando victim01 este Active.'
  fi
}

usage() {
  cat <<'HELP'
Uso: sudo ./lab.sh {start|stop|status|rebuild|reset --yes|logs [servicio]}
  start       Inicia Wazuh y luego victim01; recupera su clave si es necesario.
  stop        Guarda identidad y detiene servicios sin borrar datos.
  status      Muestra contenedores y agentes.
  rebuild     Conserva identidad, reconstruye y recrea solo atacante y victima.
  reset --yes DESTRUCTIVO: elimina volumenes y respaldos locales de identidad.
              Exige que victim01 sea el primer agente (001 Active).
  logs        Muestra los ultimos registros de servicios.

Seguridad: .lab-state contiene la clave privada del agente. No publicar en Git.
RESET borra registros de agentes, historial y datos de los volumenes del proyecto.
HELP
}

case "$ACTION" in
  start|stop|status|rebuild|reset|logs)
    require_tools
    case "$ACTION" in
      start) start_lab ;;
      stop) stop_lab ;;
      status) status_lab ;;
      rebuild) rebuild_lab ;;
      reset) reset_lab "$@" ;;
      logs) shift; "${COMPOSE[@]}" logs --tail=80 "$@" ;;
    esac
    ;;
  *) usage; exit 2 ;;
esac
