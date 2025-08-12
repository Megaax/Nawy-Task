# Use a small, maintained Node image
FROM node:20-alpine

# Create non-root user for security
USER node

# Set workdir and copy only dependency files first (better caching)
WORKDIR /app
COPY --chown=node:node package*.json ./

RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

COPY --chown=node:node . .

# App listens on 3000
ENV PORT=3000
EXPOSE 3000

# Basic healthcheck
HEALTHCHECK --interval=30s --timeout=3s --retries=3 CMD wget -qO- http://127.0.0.1:${PORT}/ || exit 1

CMD ["npm", "start"]
