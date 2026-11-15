#!/usr/bin/env bash
# FIT Lab Wazuh - gestion segura del laboratorio (solo este proyecto)
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.lab.yml)
CERT_COMPOSE=(docker compose -f generate-indexer-certs.yml)
CERT_DIR="$ROOT_DIR/config/wazuh_indexer_ssl_certs"
CERT_FILES=(root-ca.pem root-ca-manager.pem admin.pem admin-key.pem wazuh.indexer.pem wazuh.indexer-key.pem wazuh.manager.pem wazuh.manager-key.pem wazuh.dashboard.pem wazuh.dashboard-key.pem)

msg() { printf '\n[LAB] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_tools() {
  command -v docker >/dev/null 2>&1 || fail "Docker no esta instalado."
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 no esta disponible."
  docker info >/dev/null 2>&1 || fail "No hay acceso al daemon Docker. Ejecuta sudo ./lab.sh $ACTION o revisa permisos."
  [[ -f docker-compose.yml && -f docker-compose.lab.yml && -f generate-indexer-certs.yml ]] || fail "Faltan archivos Compose en $ROOT_DIR"
}

validate_compose() {
  "${COMPOSE[@]}" config --quiet
  "${CERT_COMPOSE[@]}" config --quiet
}

ensure_map_count() {
  local current
  current="$(sysctl -n vm.max_map_count 2>/dev/null || printf 0)"
  if (( current < 262144 )); then
    msg "Configurando vm.max_map_count=262144 (requiere privilegios de administrador)."
    sysctl -w vm.max_map_count=262144 >/dev/null || fail "No se pudo ajustar vm.max_map_count."
  fi
}

missing_certificates() {
  local file
  for file in "${CERT_FILES[@]}"; do
    [[ -s "$CERT_DIR/$file" ]] || return 0
  done
  return 1
}

ensure_certificates() {
  if missing_certificates; then
    msg "Faltan certificados. Generando certificados iniciales..."
    mkdir -p "$CERT_DIR"
    # No reemplazar certificados parciales: podria romper una instalacion existente.
    if find "$CERT_DIR" -mindepth 1 -maxdepth 1 -type f | grep -q .; then
      fail "Existen certificados incompletos en $CERT_DIR. Revisa antes de regenerar; no se borrara nada automaticamente."
    fi
    "${CERT_COMPOSE[@]}" run --rm generator
    missing_certificates && fail "El generador termino pero faltan certificados. Revisa su salida."
    msg "Certificados generados."
  else
    msg "Certificados existentes completos; se conservaran."
  fi
}

show_status() {
  "${COMPOSE[@]}" ps -a
  printf '\n[LAB] Agentes registrados (si Manager esta disponible):\n'
  local manager
  manager="$("${COMPOSE[@]}" ps -q wazuh.manager 2>/dev/null || true)"
  if [[ -n "$manager" ]] && [[ "$(docker inspect -f '{{.State.Running}}' "$manager" 2>/dev/null || true)" == true ]]; then
    docker exec "$manager" /var/ossec/bin/agent_control -l || true
  else
    echo "Manager no esta en ejecucion."
  fi
}

start() {
  ensure_map_count
  validate_compose
  ensure_certificates
  msg "Iniciando los cinco servicios. Si faltan imagenes personalizadas se construiran."
  "${COMPOSE[@]}" up -d --build
  msg "Contenedores y estado actual:"
  show_status
  msg "Dashboard: https://localhost (puede necesitar inicializacion)."
  msg "Si victim01 aparece desconectado tras una recreacion, revisa: docker logs victim01 | tail -n 50"
  msg "El registro previo del agente puede causar Duplicate agent name; consulta el README antes de eliminar una identidad."
}

rebuild() {
  ensure_map_count
  validate_compose
  ensure_certificates
  msg "Reconstruyendo victim01 y attacker01 sin cache. No se borraran volumenes."
  "${COMPOSE[@]}" build --no-cache --pull victim01 attacker01
  "${COMPOSE[@]}" up -d
  show_status
  msg "Aviso: recrear victim01 puede requerir nuevo enrolamiento si su client.keys no persiste."
}

stop_lab() {
  msg "Deteniendo el laboratorio sin eliminar contenedores ni datos..."
  "${COMPOSE[@]}" stop
  show_status
}

logs_lab() {
  "${COMPOSE[@]}" logs --tail=80 "${@:1}"
}

usage() {
  cat <<'HELP'
Uso: sudo ./lab.sh {start|stop|status|rebuild|logs}
  start   Valida Compose, genera certificados solo si faltan y levanta servicios
  stop    Detiene los cinco servicios, conservando datos
  status  Muestra contenedores y agentes registrados
  rebuild Reconstruye SIN cache attacker01 y victim01 y recrea si corresponde
  logs    Muestra los ultimos logs (opcional: nombre de servicio)

No ejecuta down -v, prune ni elimina certificados existentes.
HELP
}

ACTION="${1:-}"
case "$ACTION" in
  start|stop|status|rebuild|logs)
    require_tools
    case "$ACTION" in
      start) start ;;
      stop) stop_lab ;;
      status) show_status ;;
      rebuild) rebuild ;;
      logs) shift; logs_lab "$@" ;;
    esac
    ;;
  *) usage; exit 2 ;;
esac
