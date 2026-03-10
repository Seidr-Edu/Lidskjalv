FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG SONAR_SCANNER_VERSION=8.0.1.6346
ARG TEMURIN_API_BASE=https://api.adoptium.net/v3/binary/latest
ARG TARGETARCH

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    gradle \
    jq \
    maven \
    openjdk-11-jdk \
    openjdk-17-jdk \
    openjdk-21-jdk \
    python3 \
    tar \
    unzip \
    tzdata \
  && case "${TARGETARCH:-amd64}" in \
      amd64) temurin_arch="x64" ;; \
      arm64) temurin_arch="aarch64" ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac \
  && mkdir -p /opt/java/jdk8 /opt/java/jdk25 \
  && curl -fsSL -o /tmp/jdk8.tar.gz \
    "${TEMURIN_API_BASE}/8/ga/linux/${temurin_arch}/jdk/hotspot/normal/eclipse" \
  && tar -xzf /tmp/jdk8.tar.gz -C /opt/java/jdk8 --strip-components=1 \
  && /opt/java/jdk8/bin/java -version >/dev/null 2>&1 \
  && curl -fsSL -o /tmp/jdk25.tar.gz \
    "${TEMURIN_API_BASE}/25/ga/linux/${temurin_arch}/jdk/hotspot/normal/eclipse" \
  && tar -xzf /tmp/jdk25.tar.gz -C /opt/java/jdk25 --strip-components=1 \
  && /opt/java/jdk25/bin/java -version >/dev/null 2>&1 \
  && curl -fsSL -o /tmp/sonar-scanner.zip \
    "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip" \
  && unzip -q /tmp/sonar-scanner.zip -d /opt \
  && scanner_dir="$(find /opt -maxdepth 1 -type d -name 'sonar-scanner-*' | head -n 1)" \
  && test -n "${scanner_dir}" \
  && ln -s "${scanner_dir}/bin/sonar-scanner" /usr/local/bin/sonar-scanner \
  && rm -f /tmp/jdk8.tar.gz /tmp/jdk25.tar.gz /tmp/sonar-scanner.zip \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 lidskjalv \
  && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash lidskjalv

WORKDIR /app

COPY lidskjalv-service.sh /app/
COPY scripts/ /app/scripts/
COPY docs/ /app/docs/

RUN chmod +x /app/lidskjalv-service.sh /app/scripts/*.sh

USER lidskjalv

ENTRYPOINT ["/app/lidskjalv-service.sh"]
