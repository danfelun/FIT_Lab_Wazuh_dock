# Wazuh SIEM Lab – Single-node + Attacker01 + Victim01

Laboratorio académico aislado con **Wazuh 4.14.10** (Manager, Indexer y Dashboard), `victim01` (Ubuntu, SSH, rsyslog y agente Wazuh) y `attacker01` (Ubuntu con Hydra y herramientas de red). Pruebas diseñadas exclusivamente para los contenedores del proyecto, no para sistemas externos.

## Requisitos

- Ubuntu o Linux con Docker Engine y Docker Compose v2; espacio y memoria suficientes para Wazuh.
- Puertos requeridos libres, en especial **443** para el Dashboard. El archivo Compose principal también publica 1514, 1515, 514/UDP, 55000 y 9200; mantener estos accesos restringidos al laboratorio.
- Ejecutar desde la raíz del repositorio `FIT_Lab_Wazuh_dock`.
- Los archivos `docker-compose.yml`, `docker-compose.lab.yml`, `generate-indexer-certs.yml` y `config/certs.yml` deben existir. Los certificados privados se generan localmente y **no se publican en Git**.

## Iniciar el laboratorio

```bash
cd ~/Documentos/ReposGitHub/FIT_Lab_Wazuh_dock
chmod +x lab.sh
sudo ./lab.sh start
```

El script ajusta `vm.max_map_count` si hace falta, valida Docker Compose, genera los certificados TLS **solo cuando no existen**, construye las imágenes personalizadas cuando corresponde y levanta los cinco servicios. **No borra volúmenes ni certificados existentes.** En una instalación nueva puede ser necesario esperar a que Indexer, Manager y Dashboard terminen de inicializarse.

```bash
sudo ./lab.sh status                   # estado de contenedores y agentes
sudo ./lab.sh logs                     # registros recientes
sudo docker logs --tail 60 victim01    # inicio, rsyslog y agente
```

Abrir el Dashboard en **https://localhost** y seleccionar **Endpoints**: el agente `victim01` debe estar **Active**. Si el navegador advierte sobre el certificado autofirmado, revisar que se está accediendo al entorno local previsto. Utilizar las credenciales definidas en la configuración del laboratorio; no reutilizarlas en producción.

> **Agente desconectado tras reconstruir:** revisa `sudo docker logs victim01`. Si aparece `Duplicate agent name: victim01`, el Manager conserva el registro anterior mientras el contenedor recreado perdió su identidad. Comprueba primero el ID con `sudo ./lab.sh status`. En este laboratorio de un solo agente puedes retirar **solo** el registro anterior desde `manage_agents` en el Manager y permitir el nuevo enrolamiento. No borres identidades en entornos compartidos.

## Demostración 1 — autenticación SSH controlada con Hydra

1. Abrir una terminal en el atacante:

   ```bash
   sudo docker exec -it attacker01 bash
   ```

2. Dentro de `attacker01`, preparar una lista corta de contraseñas **exclusivamente de laboratorio** y ejecutar Hydra contra el contenedor `victim01`:

   ```bash
   printf 'admin\n123456\nqwerty\nDemo123!\n' > /tmp/passlist.txt
   hydra -l demo -P /tmp/passlist.txt ssh://victim01 -t 4 -V
   ```

   La cuenta de laboratorio es `demo`; su contraseña de prueba se establece en el Dockerfile. Esta secuencia debe producir intentos fallidos y potencialmente una autenticación exitosa. No dirijas la prueba a direcciones ajenas al entorno.

3. Desde otra terminal de Ubuntu, verificar que los mensajes SSH llegan a la víctima:

   ```bash
   sudo docker exec victim01 bash -c \
     "grep -Ei 'Failed password|Accepted password' /var/log/auth.log | tail -n 20"
   ```

4. En **Wazuh → Threat Hunting → Events**, seleccionar el agente `victim01`, usar un intervalo de tiempo que incluya la prueba y actualizar. Revisar las reglas y los campos `data.srcip`, `data.dstuser` y `full_log` cuando estén presentes. Un log correcto no garantiza que se dispare una regla de severidad alta: interpretar los eventos efectivamente producidos.

## Demostración 2 — integridad de archivos (FIM)

Desde Ubuntu, modificar el archivo supervisado:

```bash
sudo docker exec victim01 bash -c \
  'echo "Prueba FIM CIPAS $(date)" >> /opt/lab/crownjewels.txt'
```

En **File Integrity Monitoring** o **Threat Hunting → Events**, filtrar por `victim01` y buscar el cambio de integridad (habitualmente la regla `550`). La detección puede tardar hasta el siguiente escaneo, según `victim/ossec.conf`.

## Apagar, iniciar de nuevo y reconstruir

```bash
sudo ./lab.sh stop       # detiene sin borrar datos
sudo ./lab.sh start      # vuelve a iniciar
sudo ./lab.sh rebuild    # solo si cambian los Dockerfile; sin borrar volumenes
```

**Atención:** al reconstruir `victim01` se puede perder su clave de enrolamiento si no está persistida. Revisa el estado del agente al terminar. Para un reinicio ordinario utiliza `stop`/`start`, no `rebuild`.

## Diagnóstico mínimo

```bash
sudo ./lab.sh status
sudo docker exec victim01 date
sudo docker exec victim01 /var/ossec/bin/wazuh-control status
sudo docker exec victim01 tail -n 30 /var/log/auth.log
sudo docker logs --tail 80 victim01
```

Zona horaria prevista: **America/Bogota**. Si los eventos SSH no aparecen, revisar primero que `/var/log/auth.log` reciba mensajes y que `wazuh-logcollector` esté activo. La corrección de permisos de `rsyslog` está incorporada en `victim/entrypoint.sh`.

**Seguridad:** no publicar claves TLS, certificados privados ni contraseñas reales. No ejecutar ataques fuera de los contenedores aislados. Los puertos publicados por Docker deben restringirse al equipo o la red de prácticas.
