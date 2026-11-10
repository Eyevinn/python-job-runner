ARG PYTHON_IMAGE=python:3.12-slim

FROM ${PYTHON_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    git \
    curl \
    ca-certificates \
    build-essential \
    pkg-config \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

# Node.js required for OSC CLI (config-to-env)
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /runner
COPY ./scripts ./
RUN chmod +x ./*.sh
VOLUME /usercontent
ENTRYPOINT ["/runner/docker-entrypoint.sh"]
