FROM node:22-slim

# Install system packages
RUN apt-get update && apt-get install -y \
    git \
    vim \
    && rm -rf /var/lib/apt/lists/*

# Fail fast if GID 1000 is taken by a different group
#RUN if getent group 1000 >/dev/null; then \
#        existing=$(getent group 1000 | cut -d: -f1); \
#        [ "$existing" = "appgroup" ] || { echo "GID 1000 already used by $existing"; exit 1; }; \
#    else \
#        groupadd -g 1000 appgroup; \
#    fi

# Same for UID
#RUN if getent passwd 1000 >/dev/null; then \
#        existing=$(getent passwd 1000 | cut -d: -f1); \
#        [ "$existing" = "appuser" ] || { echo "UID 1000 already used by $existing"; exit 1; }; \
#    else \
#        useradd -m -u 1000 -g appgroup -s /bin/bash appuser; \
#    fi

# The directory that will be bind‑mounted from the host.
WORKDIR /app

# Run everything as the non‑root user we just created.
USER node