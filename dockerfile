# Use a small, maintained Node image
FROM node:20-alpine

# Create non-root user for security
USER node

# Set workdir and copy only dependency files first (better caching)
WORKDIR /app
COPY --chown=node:node package*.json ./

# Install deps (use npm ci if lockfile exists)
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

# Copy the rest of the app
COPY --chown=node:node . .

# App listens on 3000 (default for this repo)
ENV PORT=3000
EXPOSE 3000

# Basic healthcheck (optional but nice to have)
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:${PORT}/ || exit 1

# Start it up
CMD ["npm", "start"]
