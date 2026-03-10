FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    bash \
    ca-certificates \
    curl \
    git \
    gradle \
    jq \
    maven \
    openjdk-17-jdk \
    openjdk-21-jdk \
    python3 \
    tzdata \
  && rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 10001 lidskjalv \
  && useradd --uid 10001 --gid 10001 --create-home --shell /bin/bash lidskjalv

WORKDIR /app

COPY . /app

RUN chmod +x /app/lidskjalv-service.sh /app/scripts/*.sh /app/tests/run.sh

USER lidskjalv

ENTRYPOINT ["/app/lidskjalv-service.sh"]
