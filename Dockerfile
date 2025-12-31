FROM ghcr.io/berriai/litellm:main-latest

# Set working directory
WORKDIR /app

# Verify netstat is available for health checks (fail build if missing)
RUN which netstat || (echo "ERROR: netstat not found in base image" && exit 1)

# Create non-root user for running the application
RUN addgroup -g 1000 litellm && \
    adduser -D -u 1000 -G litellm litellm

# Copy configuration file
COPY config/litellm_config.yaml /app/config.yaml

# Set proper ownership for config file
RUN chown litellm:litellm /app/config.yaml

# Expose LiteLLM port
EXPOSE 4000

# Security: Drop unsupported parameters instead of failing
ENV LITELLM_DROP_PARAMS=true

# Security: Enable rate limiting
ENV ENABLE_RATE_LIMIT=true

# Switch to non-root user
USER litellm

# Health check - verify port 4000 is listening
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD netstat -ltn | grep -q ':4000 ' || exit 1

# Run LiteLLM with configuration
ENTRYPOINT ["litellm"]
CMD ["--config", "/app/config.yaml", "--port", "4000", "--detailed_debug"]
