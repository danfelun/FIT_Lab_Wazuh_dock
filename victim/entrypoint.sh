#!/usr/bin/env bash
set -e

# ==========================================
# FIT Lab Wazuh - victim01
# Inicializacion de servicios del laboratorio
# ==========================================

# 1. Preparar archivos de registro utilizados por Wazuh
echo "[INFO] Preparando archivos de registro..."

mkdir -p /var/log /run/sshd /var/run/sshd

touch /var/log/auth.log \
      /var/log/fake_auth.log \
      /var/log/lab_auth.log \
      /var/log/syslog

# Permitir que rsyslog escriba los registros del sistema
chown syslog:adm /var/log/auth.log /var/log/syslog
chmod 640 /var/log/auth.log /var/log/syslog

# Archivos adicionales utilizados en las practicas
chown root:adm /var/log/fake_auth.log /var/log/lab_auth.log
chmod 644 /var/log/fake_auth.log /var/log/lab_auth.log

# 2. Iniciar rsyslog
echo "[INFO] Iniciando rsyslog..."

/usr/sbin/rsyslogd

sleep 2

# 3. Comprobar la recepcion de registros locales
echo "[INFO] Comprobando registro de eventos..."

logger -p authpriv.notice -t FIT-LAB \
  "Inicializacion del sistema de registros de victim01"

sleep 2

if grep -q "Inicializacion del sistema de registros de victim01" \
  /var/log/auth.log; then
    echo "[OK] rsyslog escribe correctamente en auth.log"
else
    echo "[WARN] No se detecto el evento de prueba en auth.log"
fi

# 4. Iniciar servidor SSH
echo "[INFO] Iniciando servicio SSH..."

/usr/sbin/sshd

# 5. Iniciar agente Wazuh
echo "[INFO] Iniciando agente Wazuh..."

/var/ossec/bin/wazuh-control start

# 6. Mantener el contenedor activo
echo "[OK] victim01 listo. Servicios inicializados."
echo "[INFO] Supervisando registros del laboratorio..."

exec tail -F \
  /var/log/auth.log \
  /var/log/lab_auth.log \
  /var/ossec/logs/ossec.log
