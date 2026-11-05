FROM node:20-bookworm-slim AS build

WORKDIR /workspace
COPY trader-app-ui/package.json trader-app-ui/package-lock.json ./trader-app-ui/
WORKDIR /workspace/trader-app-ui
RUN npm ci
COPY trader-app-ui/ ./
RUN npm run build

FROM nginx:1.27-alpine

COPY --from=build /workspace/trader-app-ui/build/ /usr/share/nginx/html/
COPY docker/nginx/default.conf /etc/nginx/conf.d/default.conf
