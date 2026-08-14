# Build from repo root: docker build -f web/Dockerfile .
FROM node:20-bookworm AS builder

RUN apt-get update && apt-get install -y python3 make g++ && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY web/package.json web/package-lock.json ./
RUN npm ci

COPY web/ .
RUN npm run build

FROM node:20-bookworm-slim

RUN apt-get update && \
    apt-get install -y bash curl jq python3 make g++ ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install oc CLI
RUN curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /usr/local/bin oc kubectl && \
    chmod +x /usr/local/bin/oc /usr/local/bin/kubectl

# Install openshell CLI
RUN curl -fsSL https://raw.githubusercontent.com/nvidia/openshell/main/install.sh | bash

WORKDIR /app

COPY --from=builder /app/.next ./.next
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./
COPY --from=builder /app/server.mjs ./
COPY --from=builder /app/proto ./proto
COPY --from=builder /app/lab ./lab

# node-pty's native addon must be compiled against the runtime's libs
RUN cd node_modules/node-pty && npx node-gyp rebuild

# Manifests needed by API routes and fleet operations
COPY manifests/demo-app /app/manifests/demo-app
COPY manifests/openclaw /app/manifests/openclaw
COPY policies /app/policies
COPY scripts/fleet.sh scripts/lib /app/scripts/

COPY web/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV NODE_ENV=production \
    PORT=3000 \
    HOST=0.0.0.0 \
    LAB_CWD=/app

EXPOSE 3000

ENTRYPOINT ["bash", "/app/entrypoint.sh"]
