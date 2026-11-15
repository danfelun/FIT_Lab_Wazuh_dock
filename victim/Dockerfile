FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Bogota
ENV WAZUH_MANAGER=wazuh.manager
ENV WAZUH_AGENT_NAME=victim01

# ==========================================
# 1. Dependencias y herramientas del sistema
# ==========================================

RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    apt-transport-https \
    lsb-release \
    ca-certificates \
    openssh-server \
    rsyslog \
    procps \
    vim \
    net-tools \
    iproute2 \
    sudo \
    && mkdir -p /run/sshd /var/run/sshd \
    && useradd -m -s /bin/bash demo \
    && echo 'demo:Demo123!' | chpasswd \
    && usermod -aG sudo demo \
    && mkdir -p /opt/lab \
    && echo 'archivo sensible' > /opt/lab/crownjewels.txt \
    && chmod 600 /opt/lab/crownjewels.txt \
    && rm -rf /var/lib/apt/lists/*

# ==========================================
# 2. Repositorio e instalacion del agente Wazuh
# ==========================================

RUN curl -fsSL \
    https://packages.wazuh.com/key/GPG-KEY-WAZUH \
    | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg \
    && echo \
    "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
    > /etc/apt/sources.list.d/wazuh.list \
    && apt-get update \
    && WAZUH_MANAGER=${WAZUH_MANAGER} \
       WAZUH_AGENT_NAME=${WAZUH_AGENT_NAME} \
       apt-get install -y wazuh-agent=4.14.10-1 \
    && apt-mark hold wazuh-agent \
    && rm -rf /var/lib/apt/lists/*

# ==========================================
# 3. Configuracion SSH y agente Wazuh
# ==========================================

COPY sshd_config /etc/ssh/sshd_config

COPY ossec.conf /var/ossec/etc/ossec.conf

# ==========================================
# 4. Configuracion de rsyslog para Docker
# ==========================================

# Deshabilitar lectura de logs del kernel.
# Los contenedores no tienen acceso a /proc/kmsg.
RUN sed -i \
    '/module(load="imklog"/s/^/# /' \
    /etc/rsyslog.conf

# Mantener habilitado imuxsock para recibir
# mensajes locales mediante /dev/log.
# Ubuntu ya configura auth/authpriv en 50-default.conf.
# No agregar reglas duplicadas en 50-auth.conf.
RUN rm -f /etc/rsyslog.d/50-auth.conf

# ==========================================
# 5. Script de inicializacion
# ==========================================

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# ==========================================
# 6. Puerto SSH del laboratorio
# ==========================================

EXPOSE 22

# ==========================================
# 7. Inicio del contenedor
# ==========================================

CMD ["/entrypoint.sh"]