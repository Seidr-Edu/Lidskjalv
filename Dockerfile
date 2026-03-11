FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG SONAR_SCANNER_VERSION=8.0.1.6346
ARG SONAR_SCANNER_SHA256=8fbfb1eb546b734a60fc3e537108f06e389a8ca124fbab3a16236a8a51edcc15
ARG TEMURIN_JDK8_RELEASE=jdk8u482-b08
ARG TEMURIN_JDK8_VERSION=8u482b08
ARG TEMURIN_JDK8_X64_SHA256=e74becad56b4cc01f1556a671e578d3788789f5257f9499f6fbed84e63a55ecf
ARG TEMURIN_JDK8_AARCH64_SHA256=ada72fbf191fb287b4c1e54be372b64c40c27c2ffbfa01f880c92af11f4e7c94
ARG TEMURIN_JDK25_RELEASE=jdk-25.0.2%2B10
ARG TEMURIN_JDK25_VERSION=25.0.2_10
ARG TEMURIN_JDK25_X64_SHA256=987387933b64b9833846dee373b640440d3e1fd48a04804ec01a6dbf718e8ab8
ARG TEMURIN_JDK25_AARCH64_SHA256=a9d73e711d967dc44896d4f430f73a68fd33590dabc29a7f2fb9f593425b854c
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
      amd64) \
        temurin_arch="x64"; \
        jdk8_sha256="${TEMURIN_JDK8_X64_SHA256}"; \
        jdk25_sha256="${TEMURIN_JDK25_X64_SHA256}"; \
        ;; \
      arm64) \
        temurin_arch="aarch64"; \
        jdk8_sha256="${TEMURIN_JDK8_AARCH64_SHA256}"; \
        jdk25_sha256="${TEMURIN_JDK25_AARCH64_SHA256}"; \
        ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH:-unknown}" >&2; exit 1 ;; \
    esac \
  && mkdir -p /opt/java/jdk8 /opt/java/jdk25 \
  && curl -fsSL -o /tmp/jdk8.tar.gz \
    "https://github.com/adoptium/temurin8-binaries/releases/download/${TEMURIN_JDK8_RELEASE}/OpenJDK8U-jdk_${temurin_arch}_linux_hotspot_${TEMURIN_JDK8_VERSION}.tar.gz" \
  && echo "${jdk8_sha256}  /tmp/jdk8.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/jdk8.tar.gz -C /opt/java/jdk8 --strip-components=1 \
  && /opt/java/jdk8/bin/java -version >/dev/null 2>&1 \
  && curl -fsSL -o /tmp/jdk25.tar.gz \
    "https://github.com/adoptium/temurin25-binaries/releases/download/${TEMURIN_JDK25_RELEASE}/OpenJDK25U-jdk_${temurin_arch}_linux_hotspot_${TEMURIN_JDK25_VERSION}.tar.gz" \
  && echo "${jdk25_sha256}  /tmp/jdk25.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/jdk25.tar.gz -C /opt/java/jdk25 --strip-components=1 \
  && /opt/java/jdk25/bin/java -version >/dev/null 2>&1 \
  && curl -fsSL -o /tmp/sonar-scanner.zip \
    "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip" \
  && echo "${SONAR_SCANNER_SHA256}  /tmp/sonar-scanner.zip" | sha256sum -c - \
  && unzip -q /tmp/sonar-scanner.zip -d /opt \
  && scanner_dir="$(find /opt -maxdepth 1 -type d -name 'sonar-scanner-*' | head -n 1)" \
  && test -n "${scanner_dir}" \
  && ln -s "${scanner_dir}/bin/sonar-scanner" /usr/local/bin/sonar-scanner \
  && rm -f /tmp/jdk8.tar.gz /tmp/jdk25.tar.gz /tmp/sonar-scanner.zip \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 lidskjalv \
  && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin lidskjalv \
  && mkdir -p /run \
  && chown -R lidskjalv:lidskjalv /run

WORKDIR /app

COPY lidskjalv-service.sh /app/
COPY scripts/ /app/scripts/
COPY docs/ /app/docs/

RUN chmod +x /app/lidskjalv-service.sh /app/scripts/*.sh \
  && chown -R lidskjalv:lidskjalv /app

USER lidskjalv

ENV HOME=/home/lidskjalv

ENTRYPOINT ["/app/lidskjalv-service.sh"]
