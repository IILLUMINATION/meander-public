# Слепой ретранслятор TLS: один файл, без зависимостей.
FROM node:22-alpine

WORKDIR /app
COPY server.js .

# Цель по умолчанию — основной домен: контейнер годится и для стороннего
# хостера как есть. Если ретранслятор стоит на том же сервере, что и бэкенд,
# задайте RELAY_TARGET_HOST=127.0.0.1 (см. relay/meander-tunnel.service).
ENV RELAY_LISTEN_HOST=0.0.0.0 \
    RELAY_LISTEN_PORT=8443 \
    RELAY_TARGET_HOST=meander.illuminat.dev \
    RELAY_TARGET_PORT=443

EXPOSE 8443
USER node

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD node -e "require('net').connect(Number(process.env.RELAY_LISTEN_PORT||8443),'127.0.0.1').once('connect',()=>process.exit(0)).once('error',()=>process.exit(1))"

CMD ["node", "server.js"]