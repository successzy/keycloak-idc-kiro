# syntax=docker/dockerfile:1.7
# =============================================================================
# Keycloak production image for kiro-idp
#
# Stage 1 (builder): install custom SPI, pre-configure providers and run
#   `kc.sh build` so that start-up is fast and no build happens at runtime.
# Stage 2 (runtime): copy the optimized /opt/keycloak from the builder.
# =============================================================================

ARG KEYCLOAK_VERSION=26.2.4

# ---------- Stage 1: builder ----------
FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION} AS builder

# Features / options baked into the image at build time.
# These MUST be set before `kc.sh build` to be compiled into the server.
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_CACHE=ispn \
    KC_CACHE_STACK=jdbc-ping \
    KC_HTTP_RELATIVE_PATH=/ \
    KC_LOG_CONSOLE_OUTPUT=json

# Install custom provider (IP whitelist SPI).
COPY --chown=keycloak:keycloak providers/ /opt/keycloak/providers/

# Optional: custom themes. Create the directory so COPY doesn't fail if empty.
COPY --chown=keycloak:keycloak themes/ /opt/keycloak/themes/

# Compile configuration into an optimized server.
RUN /opt/keycloak/bin/kc.sh build

# ---------- Stage 2: runtime ----------
FROM quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}

# Copy the optimized distribution from the builder stage.
COPY --from=builder /opt/keycloak/ /opt/keycloak/

# Non-root user is already set by the base image (UID 1000).

# Default runtime parameters (container start args). Environment variables
# that can change between deployments (KC_DB_URL, KC_HOSTNAME, secrets, etc.)
# are NOT set here - they should be injected by the orchestrator (ECS).
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized"]

# Image metadata.
LABEL org.opencontainers.image.title="kc-keycloak" \
      org.opencontainers.image.description="Keycloak with IP-whitelist SPI for Kiro IdP" \
      org.opencontainers.image.base.name="quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}"
