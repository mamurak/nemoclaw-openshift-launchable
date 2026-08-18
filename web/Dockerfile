# Build from repo root: docker build -f web/Dockerfile .
FROM node:20-bookworm AS builder

RUN apt-get update && apt-get install -y \
    python3=3.11.2-1+b1 \
    make=4.3-4.1 \
    g++=4:12.2.0-3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY web/package.json web/package-lock.json ./
RUN npm ci

COPY web/ .
RUN npm run build

FROM node:20-bookworm-slim

RUN apt-get update && \
    apt-get install -y \
    bash=5.2.15-2+b13 \
    curl=7.88.1-10+deb12u15 \
    jq=1.6-2.1+deb12u2 \
    python3=3.11.2-1+b1 \
    make=4.3-4.1 \
    g++=4:12.2.0-3 \
    ca-certificates=20250419~deb12u1 \
    openssl=3.0.20-1~deb12u2 \
    openssh-client=1:9.2p1-2+deb12u10 \
    nano=7.2-1+deb12u1 \
    vim-tiny=2:9.0.1378-2+deb12u2 \
    && rm -rf /var/lib/apt/lists/*

# Install oc CLI
RUN curl -sL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar xzf - -C /usr/local/bin oc kubectl && \
    chmod +x /usr/local/bin/oc /usr/local/bin/kubectl

# Install openshell CLI — pin to gateway version to avoid protocol mismatches
RUN curl -fsSL https://raw.githubusercontent.com/nvidia/openshell/main/install.sh -o /tmp/install-openshell.sh && \
    OPENSHELL_VERSION=v0.0.71 bash /tmp/install-openshell.sh && \
    rm /tmp/install-openshell.sh && \
    cp /root/.openshell/bin/openshell /usr/local/bin/openshell 2>/dev/null || true

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
COPY fleet.txt /app/fleet.txt

COPY web/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh && \
    chmod g+w /app

ENV NODE_ENV=production \
    PORT=3000 \
    HOST=0.0.0.0 \
    LAB_CWD=/app

EXPOSE 3000

ENTRYPOINT ["bash", "/app/entrypoint.sh"]
