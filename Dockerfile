# Node for the web app, Python for the Excel/PDF extractor — one image.
FROM node:22-bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 python3-pip python3-venv \
      build-essential python3-dev \
      libjpeg62-turbo libopenjp2-7 \
      ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Python deps in a venv so we never fight the system package manager
ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
COPY ingest/requirements.txt ./ingest/requirements.txt
RUN pip install --no-cache-dir -r ingest/requirements.txt

# Node deps (better-sqlite3 compiles here, then we drop the toolchain)
COPY package*.json ./
RUN npm ci --omit=dev || npm install --omit=dev

COPY . .

RUN apt-get purge -y build-essential python3-dev && apt-get autoremove -y \
 && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production \
    PORT=3000 \
    DATA_DIR=/app/data \
    ORDER_FORMS_DIR="/app/Order Forms" \
    PYTHON_BIN=/opt/venv/bin/python3

RUN mkdir -p /app/data "/app/Order Forms"
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
  CMD curl -fsS http://127.0.0.1:3000/healthz || exit 1

CMD ["node", "src/server.js"]
