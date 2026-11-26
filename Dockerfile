# MAKING — workers (init.sh) + dashboard in one container
FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bash curl jq bc util-linux procps python3 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app/making

ARG MAKING_REV=dev
ENV MAKING_ROOT=/app/making \
    DASHBOARD_BASE_PATH=/making \
    MAKING_IMAGE_REV=${MAKING_REV} \
    PYTHONUNBUFFERED=1

COPY . .
RUN chmod +x docker/entrypoint.sh \
    && chmod +x init.sh mt5 dashboard/server.py SWINGKING/swingking.sh SWINGKING/watch_ack.sh 2>/dev/null || true \
    && echo "${MAKING_REV}" > dashboard/STATIC_VER \
    && mkdir -p logs pids data env

EXPOSE 8877

HEALTHCHECK --interval=30s --timeout=8s --start-period=20s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:8877/making/api/health" || exit 1

ENTRYPOINT ["/app/making/docker/entrypoint.sh"]