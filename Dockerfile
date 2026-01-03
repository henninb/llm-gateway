# Pin to specific version with known bug (see docs/litellm-bug-modifyresponseexception-streaming.md)
# DO NOT upgrade to :main-latest until the bug is fixed upstream
FROM ghcr.io/berriai/litellm:main-v1.80.11

# Set working directory
WORKDIR /app

# Verify netstat is available for health checks (fail build if missing)
RUN which netstat || (echo "ERROR: netstat not found in base image" && exit 1)

# Apply fix for ModifyResponseException streaming bug in LiteLLM 1.80.11
# See LITELLM-BUG.md for details
COPY patches/apply_litellm_fix.py /tmp/
RUN python3 /tmp/apply_litellm_fix.py && rm /tmp/apply_litellm_fix.py

# Create non-root user for running the application
RUN addgroup -g 1000 litellm && \
    adduser -D -u 1000 -G litellm litellm

# Copy configuration file
COPY config/litellm_config.yaml /app/config.yaml

# Copy custom guardrail module
COPY config/custom_guardrail.py /app/custom_guardrail.py

# Set proper ownership for config files
RUN chown litellm:litellm /app/config.yaml /app/custom_guardrail.py

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
