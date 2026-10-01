FROM node:24.20.0-slim AS base

WORKDIR /app
RUN corepack enable pnpm

FROM base AS pruner
COPY . .
RUN pnpm dlx turbo@2.11.5 prune web --docker

FROM base AS builder
COPY --from=pruner /app/out/json/ ./
COPY --from=pruner /app/out/pnpm-lock.yaml ./pnpm-lock.yaml
COPY --from=pruner /app/out/pnpm-workspace.yaml ./pnpm-workspace.yaml
RUN pnpm install --frozen-lockfile
COPY --from=pruner /app/out/full/ ./
RUN pnpm turbo run build --filter=web && \
    if [ -d apps/web/public ]; then cp -R apps/web/public apps/web/.next/standalone/apps/web/public; fi && \
    mkdir -p apps/web/.next/standalone/apps/web/.next/cache

FROM gcr.io/distroless/nodejs24-debian13:nonroot AS runner
WORKDIR /app
ENV NODE_ENV=production PORT=8080 HOSTNAME=0.0.0.0
COPY --from=builder --chown=65532:65532 /app/apps/web/.next/standalone ./
COPY --from=builder --chown=65532:65532 /app/apps/web/.next/static ./apps/web/.next/static
USER 65532:65532
EXPOSE 8080
CMD ["apps/web/server.js"]