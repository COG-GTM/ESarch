# Axon Trader UI image: replaces the TAS staticfile_buildpack (see docs/migration/tas-gke-mapping.md CHG-14).
# docker build -t trader-ui trader-app-ui && docker run --rm -p 127.0.0.1:8090:8080 trader-ui

FROM node:22-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY public ./public
COPY src ./src
COPY scripts ./scripts
RUN npm run build

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build /usr/share/nginx/html
# Runs as the image's unprivileged nginx user (uid 101) on 8080. To point the bundle at another API root, mount a
# replacement for /usr/share/nginx/html/config.js (see public/config.js).
EXPOSE 8080
