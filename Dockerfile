# syntax=docker/dockerfile:1.7

# ── Stage 1: Extensions ──────────────────────────────────────────
ARG OPENCLAW_NODE_BOOKWORM_IMAGE="node:24-bookworm"
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS ext-deps
ARG OPENCLAW_EXTENSIONS=""
COPY extensions /tmp/extensions
RUN mkdir -p /out && \
    for ext in $OPENCLAW_EXTENSIONS; do \
      if [ -f "/tmp/extensions/$ext/package.json" ]; then \
        mkdir -p "/out/$ext" && \
        cp "/tmp/extensions/$ext/package.json" "/out/$ext/package.json"; \
      fi; \
    done

# ── Stage 2: Build ──────────────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE} AS build

# Install Bun
RUN set -eux; \
    for attempt in 1 2 3 4 5; do \
      if curl --retry 5 --retry-all-errors --retry-delay 2 -fsSL https://bun.sh/install | bash; then \
        break; \
      fi; \
      sleep $((attempt * 2)); \
    done
ENV PATH="/root/.bun/bin:${PATH}"
RUN corepack enable

WORKDIR /app

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
COPY ui/package.json ./ui/package.json
COPY patches ./patches
COPY --from=ext-deps /out/ ./extensions/

# 移除 --mount 缓存，直接安装依赖
RUN NODE_OPTIONS=--max-old-space-size=2048 pnpm install --frozen-lockfile

COPY . .

# 权限规范化
RUN for dir in /app/extensions /app/.agent /app/.agents; do \
      if [ -d "$dir" ]; then \
        find "$dir" -type d -exec chmod 755 {} +; \
        find "$dir" -type f -exec chmod 644 {} +; \
      fi; \
    done

RUN pnpm canvas:a2ui:bundle || (mkdir -p src/canvas-host/a2ui && echo "/* stub */" > src/canvas-host/a2ui/a2ui.bundle.js)
RUN pnpm build:docker
ENV OPENCLAW_PREFER_PNPM=1
RUN pnpm ui:build

# ── Runtime Assets ──────────────────────────────────────────────
FROM build AS runtime-assets
RUN CI=true pnpm prune --prod && \
    find dist -type f \( -name '*.d.ts' -o -name '*.d.mts' -o -name '*.d.cts' -o -name '*.map' \) -delete

# ── Stage 3: Runtime ────────────────────────────────────────────
FROM ${OPENCLAW_NODE_BOOKWORM_IMAGE}

WORKDIR /app

# 移除 apt 缓存挂载，使用标准安装
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      procps hostname curl git lsof openssl

RUN chown node:node /app

COPY --from=runtime-assets --chown=node:node /app/dist ./dist
COPY --from=runtime-assets --chown=node:node /app/node_modules ./node_modules
COPY --from=runtime-assets --chown=node:node /app/package.json .
COPY --from=runtime-assets --chown=node:node /app/openclaw.mjs .
COPY --from=runtime-assets --chown=node:node /app/extensions ./extensions
COPY --from=runtime-assets --chown=node:node /app/skills ./skills
COPY --from=runtime-assets --chown=node:node /app/docs ./docs

ENV OPENCLAW_BUNDLED_PLUGINS_DIR=/app/extensions
ENV COREPACK_HOME=/usr/local/share/corepack
RUN install -d -m 0755 "$COREPACK_HOME" && \
    corepack enable && \
    corepack prepare "$(node -p "require('./package.json').packageManager")" --activate && \
    chmod -R a+rX "$COREPACK_HOME"

# 针对 Railway 优化：移除所有 --mount 相关的条件安装
ARG OPENCLAW_DOCKER_APT_PACKAGES=""
RUN if [ -n "$OPENCLAW_DOCKER_APT_PACKAGES" ]; then \
      apt-get update && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $OPENCLAW_DOCKER_APT_PACKAGES; \
    fi

RUN ln -sf /app/openclaw.mjs /usr/local/bin/openclaw && chmod 755 /app/openclaw.mjs

ENV NODE_ENV=production
USER node

# 注意：为了让 Railway 外部能访问，绑定到 0.0.0.0
# CMD ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "lan"]
# CMD ["/bin/sh", "-c", "echo '{\"gateway\":{\"bind\":\"lan\",\"controlUi\":{\"allowedOrigins\":[\"https://openclaw-production-0c41.up.railway.app\"],\"dangerouslyAllowHostHeaderOriginFallback\":true}}}' > openclaw.json && node openclaw.mjs gateway --allow-unconfigured"]
CMD ["/bin/sh", "-c", "mkdir -p /data/.openclaw /data/workspace || true; echo '{\"gateway\":{\"bind\":\"lan\",\"controlUi\":{\"allowedOrigins\":[\"https://openclaw-production-0c41.up.railway.app\"],\"dangerouslyAllowHostHeaderOriginFallback\":true}}}' > openclaw.json && node openclaw.mjs gateway --allow-unconfigured --bind lan"]
