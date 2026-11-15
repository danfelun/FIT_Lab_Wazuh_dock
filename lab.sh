#!/usr/bin/env bash
# FIT Lab Wazuh - gestion y reinicio controlado (solo este proyecto)
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"
PROJECT="fit_lab_wazuh_dock"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.lab.yml)
CERT_COMPOSE=(docker compose -p "${PROJECT}_certs" -f generate-indexer-certs.yml)
CERT_DIR="$ROOT_DIR/config/wazuh_indexer_ssl_certs"
CERT_FILES=(root-ca.pem root-ca-manager.pem admin.pem admin-key.pem wazuh.indexer.pem wazuh.indexer-key.pem wazuh.manager.pem wazuh.manager-key.pem wazuh.dashboard.pem wazuh.dashboard-key.pem)
MANAGER_WAIT=180
AGENT_WAIT=120

say() { printf '\n[LAB] %s\n' "$*"; }
warn() { printf '\n[ADVERTENCIA] %s\n' "$*" >&2; }
fail() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

require_tools() {
  command -v docker >/dev/null 2>&1 || fail "Docker no esta instalado."
  command -v sysctl >/dev/null 2>&1 || fail "No se encuentra sysctl."
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 no esta disponible."
  docker info >/dev/null 2>&1 || fail "Sin acceso a Docker. Ejecuta: sudo ./lab.sh $ACTION"
  [[ -f docker-compose.yml && -f docker-compose.lab.yml && -f generate-indexer-certs.yml && -f config/certs.yml ]] || fail "Faltan archivos de configuracion en $ROOT_DIR."
}

validate_compose() {
  "${COMPOSE[@]}" config --quiet || fail "Los Compose principales no son validos."
  "${CERT_COMPOSE[@]}" config --quiet || fail "El Compose de certificados no es valido."
}

ensure_map_count() {
  local current
  current="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  if ((current < 262144)); then
    say "Ajustando vm.max_map_count a 262144..."
    sysctl -w vm.max_map_count=262144 >/dev/null || fail "No se pudo ajustar vm.max_map_count."
  fi
}

missing_certs() {
  local f
  for f in "${CERT_FILES[@]}"; do
    [[ -s "$CERT_DIR/$f" ]] || return 0
  done
  return 1
}

ensure_certs() {
  if ! missing_certs; then
    say "Certificados existentes completos; se conservaran."
    return
  fi
  mkdir -p "$CERT_DIR"
  if find "$CERT_DIR" -mindepth 1 -maxdepth 1 -type f -print -quit | grep -q .; then
    fail "Existen certificados incompletos. No se reemplazaran: $CERT_DIR"
  fi
  say "Generando certificados del laboratorio..."
  "${CERT_COMPOSE[@]}" run --rm generator
  missing_certs && fail "Faltan certificados despues de ejecutar el generador."
}

manager_id() { "${COMPOSE[@]}" ps -q wazuh.manager; }

wait_manager() {
  local cid elapsed
  cid="$(manager_id)"
  [[ -n "$cid" ]] || fail "No se encontro el contenedor del Manager."
  say "Esperando a wazuh-db, wazuh-remoted y wazuh-authd (hasta ${MANAGER_WAIT}s)..."
  for ((elapsed=0; elapsed<MANAGER_WAIT; elapsed+=5)); do
    if docker exec "$cid" /var/ossec/bin/wazuh-control status 2>/dev/null \
      | grep -q 'wazuh-db is running' && \
       docker exec "$cid" /var/ossec/bin/wazuh-control status 2>/dev/null \
      | grep -q 'wazuh-remoted is running' && \
       docker exec "$cid" /var/ossec/bin/wazuh-control status 2>/dev/null \
      | grep -q 'wazuh-authd is running'; then
      say "Manager listo."
      return 0
    fi
    sleep 5
  done
  "${COMPOSE[@]}" logs --tail=60 wazuh.manager >&2 || true
  fail "El Manager no completo su inicio; NO se ha iniciado victim01."
}

list_agents() {
  local cid
  cid="$(manager_id 2>/dev/null || true)"
  if [[ -z "$cid" ]] || ! docker inspect -f '{{.State.Running}}' "$cid" 2>/dev/null | grep -qx true; then
    warn "Manager no disponible para consultar agentes."
    return 1
  fi
  docker exec "$cid" /var/ossec/bin/agent_control -l
}

wait_agent() {
  local cid elapsed listing
  cid="$(manager_id)"
  say "Esperando registro y conexion del agente victim01 (hasta ${AGENT_WAIT}s)..."
  for ((elapsed=0; elapsed<AGENT_WAIT; elapsed+=5)); do
    listing="$(docker exec "$cid" /var/ossec/bin/agent_control -l 2>/dev/null || true)"
    if printf '%s\n' "$listing" | grep -Eq 'ID: [0-9]+, Name: victim01, .*Active'; then
      say "Agente activo:"
      printf '%s\n' "$listing" | grep 'Name: victim01' || true
      return 0
    fi
    if docker exec victim01 sh -c 'grep -q "Duplicate agent name" /var/ossec/logs/ossec.log' 2>/dev/null; then
      warn "Registro rechazado por nombre duplicado. No se borraran agentes automaticamente."
      break
    fi
    sleep 5
  done
  warn "victim01 no se encuentra Active. Resumen de agentes y logs:"
  list_agents || true
  docker logs --tail=45 victim01 >&2 || true
  return 1
}

start_lab() {
  ensure_map_count
  validate_compose
  ensure_certs
  # Arrancar los servicios centrales primero: evita enrolamiento antes de authd/wazuh-db.
  say "Levantando Indexer, Manager, Dashboard y atacante..."
  "${COMPOSE[@]}" up -d wazuh.indexer wazuh.manager wazuh.dashboard attacker01
  wait_manager
  say "Iniciando victim01 una vez que el Manager esta listo..."
  "${COMPOSE[@]}" up -d victim01
  "${COMPOSE[@]}" ps -a
  if ! wait_agent; then
    warn "Stack levantado, pero agente no validado. No declares el laboratorio listo para CIPAS."
    return 1
  fi
  say "Laboratorio listo. Dashboard: https://localhost"
  say "Verificar detecciones reales SSH y FIM antes de la sesion."
}

reset_lab() {
  [[ "${2:-}" == "--yes" ]] || fail "Operacion DESTRUCTIVA. Uso: sudo ./lab.sh reset --yes"
  validate_compose
  say "ATENCION: se borraran contenedores, redes administradas y TODOS los volumenes del proyecto $PROJECT."
  say "Se perderan alertas, indices y registros de agentes. No se tocaran otros proyectos ni certificados locales."
  "${COMPOSE[@]}" down --volumes --remove-orphans
  # Evitar que alguna configuracion externa reutilice datos anteriores sin advertirlo.
  local leftovers
  leftovers="$(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT")"
  if [[ -n "$leftovers" ]]; then
    printf '%s\n' "$leftovers" >&2
    fail "Quedaron volumenes etiquetados del proyecto. Revisalos antes de iniciar."
  fi
  say "Reconstruyendo imagenes personalizadas sin cache..."
  "${COMPOSE[@]}" build --no-cache --pull victim01 attacker01
  start_lab || fail "La instalacion nueva no paso la verificacion del agente. Revisa el diagnostico anterior."
  say "Comprobando que victim01 haya recibido el primer ID (001)..."
  local listing
  listing="$(docker exec "$(manager_id)" /var/ossec/bin/agent_control -l)"
  if printf '%s\n' "$listing" | grep -Eq 'ID: 001, Name: victim01, .*Active'; then
    say "CONFIRMADO: victim01 es el agente 001 y esta Active."
  else
    warn "El agente esta conectado, pero NO se confirmo ID 001. Revisa si hay otros agentes o almacenamiento externo."
    printf '%s\n' "$listing"
    return 1
  fi
}

rebuild_lab() {
  validate_compose
  warn "Reconstruir victim01 puede perder client.keys; si el Manager conserva su registro, el nuevo enrolamiento podria ser rechazado."
  warn "Para garantizar agente 001 desde cero, usa: sudo ./lab.sh reset --yes"
  "${COMPOSE[@]}" build --no-cache --pull victim01 attacker01
  "${COMPOSE[@]}" up -d --no-deps --force-recreate attacker01 victim01
  if ! wait_agent; then return 1; fi
}

status_lab() {
  "${COMPOSE[@]}" ps -a
  printf '\n[LAB] Agentes registrados:\n'
  list_agents || true
}

usage() {
  cat <<'HELP'
Uso: sudo ./lab.sh {start|stop|status|rebuild|reset --yes|logs [servicio]}
  start       Inicia stack en orden, espera Manager y comprueba agente Active
  stop        Detiene contenedores; conserva todos los datos
  status      Consulta contenedores y agentes
  rebuild     Reconstruye victim01/attacker01 (puede requerir re-enrolamiento)
  reset --yes BORRA contenedores, redes y volumenes del proyecto, reconstruye,
              registra el primer agente y EXIGE ID 001 Active
  logs        Muestra logs recientes

IMPORTANTE: reset --yes es destructivo para datos del laboratorio.
NO elimina certificados, imagenes de otros proyectos ni archivos del repositorio.
HELP
}

ACTION="${1:-}"
case "$ACTION" in
  start|stop|status|rebuild|reset|logs)
    require_tools
    case "$ACTION" in
      start) start_lab ;;
      stop) "${COMPOSE[@]}" stop ;;
      status) status_lab ;;
      rebuild) rebuild_lab ;;
      reset) reset_lab "$@" ;;
      logs) shift; "${COMPOSE[@]}" logs --tail=80 "$@" ;;
    esac
    ;;
  *) usage; exit 2 ;;
esac
