FROM eclipse-temurin:21-jre-jammy

RUN apt-get update && apt-get install -y \
    awscli \
    curl \
    openjdk-8-jre \
    && rm -rf /var/lib/apt/lists/*

# Install mcrcon for RCON health checks
RUN curl -sSL https://github.com/Tiiffi/mcrcon/releases/download/v0.7.2/mcrcon-0.7.2-linux-x86-64.tar.gz \
    | tar -xz -C /usr/local/bin mcrcon \
    && chmod +x /usr/local/bin/mcrcon

RUN groupadd -g 1000 minecraft && useradd -u 1000 -g minecraft -m minecraft

WORKDIR /minecraft

COPY start.sh /docker/start.sh
RUN sed -i 's/\r//' /docker/start.sh && chmod +x /docker/start.sh

EXPOSE 25565 25575

USER minecraft

ENTRYPOINT ["bash", "/docker/start.sh"]
