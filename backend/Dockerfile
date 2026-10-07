FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

FROM node:22-bookworm-slim
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8787 NODE_EXTRA_CA_CERTS=/app/supabase-ca.crt
WORKDIR /app
COPY supabase-ca.crt ./supabase-ca.crt
COPY --from=build /app/package*.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
RUN mkdir /app/.local && chown node:node /app/.local
USER node
EXPOSE 8787
CMD ["node", "dist/main.js"]
