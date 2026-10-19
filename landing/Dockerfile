# Builds the static site, then serves it with nginx on $PORT (Railway injects it).
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# Absolute URL for canonical, Open Graph and the sitemap; set it as a Railway service variable.
ARG SITE_URL
# Self-hosted Plausible origin (e.g. https://plausible.example.com); unset builds without analytics.
ARG PLAUSIBLE_HOST
ARG PLAUSIBLE_DOMAIN
RUN npm run build

FROM nginx:1.27-alpine
ENV PORT=8080
# The same origin goes into the CSP connect-src (empty when analytics is off).
ARG PLAUSIBLE_HOST=""
ENV PLAUSIBLE_HOST=$PLAUSIBLE_HOST
# The official image runs envsubst on /etc/nginx/templates/*.template at start.
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
