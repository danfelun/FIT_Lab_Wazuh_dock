FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=America/Bogota

RUN apt-get update && apt-get install -y \
    tzdata \
    nmap hydra openssh-client curl wget iputils-ping netcat-traditional \
    vim procps inetutils-tools \
    && ln -snf /usr/share/zoneinfo/America/Bogota /etc/localtime \
    && echo "America/Bogota" > /etc/timezone \
    && rm -rf /var/lib/apt/lists/* 

CMD ["sleep", "infinity"]
