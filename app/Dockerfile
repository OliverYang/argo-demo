# Multi-stage build.
# Stage 1 exists only to install deps; stage 2 ships nothing but runtime.
# The reason to split: build tooling and dev dependencies never reach the
# final image, which is what keeps the attack surface and image size down.
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json ./
# No dependencies today, but keeping this layer means adding one later
# does not require touching the Dockerfile. mkdir first: with an empty
# dependency list npm creates no node_modules, and the COPY below would
# fail with "\"/app/node_modules\": not found".
RUN mkdir -p node_modules && npm install --omit=dev

FROM node:22-alpine AS runtime
WORKDIR /app

# The version is baked in at BUILD time from the git SHA, not injected by the
# manifest. That way the running app can never disagree with its image tag:
# the identity of the artifact is fixed when the artifact is made.
ARG APP_VERSION=dev

# Run as a non-root user. K8s pods run as root by default, which is a
# well-known privilege escalation vector.
RUN addgroup -S app && adduser -S app -G app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json server.js ./
RUN chown -R app:app /app
USER app

ENV NODE_ENV=production \
    PORT=8080 \
    APP_VERSION=${APP_VERSION}

EXPOSE 8080

# The image stays environment-agnostic: only the ENVIRONMENT name is
# injected at deploy time via the Deployment env.
CMD ["node", "server.js"]
