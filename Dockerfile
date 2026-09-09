FROM crystallang/crystal:latest AS builder
WORKDIR /app
COPY shard.yml shard.lock ./
RUN shards install --production
COPY src/ src/
RUN mkdir -p bin && \
    crystal build src/agent/main.cr -o bin/command_runner && \
    crystal build src/server/main.cr -o bin/central_server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libevent-2.1-7 libpcre2-8-0 libgc1 libyaml-0-2 libpq5 ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=builder /app/bin/ /app/bin/
