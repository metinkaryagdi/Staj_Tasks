FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
# Fatura Servisi'nin tarayıcıdan görünen adresi; derleme sırasında koda gömülür (docker-compose.yml'deki build arg).
ARG VITE_API_URL=http://localhost:5090
ENV VITE_API_URL=$VITE_API_URL
# Keycloak'ın tarayıcıdan görünen adresi; giriş sayfasına buradan gidilir.
ARG VITE_KEYCLOAK_URL=http://localhost:8080
ENV VITE_KEYCLOAK_URL=$VITE_KEYCLOAK_URL
RUN npm run build

FROM nginx:alpine
# nginx imajı container açılırken templates/ altındaki dosyaları ortam değişkenleriyle doldurup /etc/nginx/conf.d/'ye
# yazar (envsubst; yalnız tanımlı değişkenler, nginx'in kendi $uri'si olduğu gibi kalır). CSP, ekranın derlendiği
# adreslere istek atılmasına izin verir: adresler yukarıdaki build arg'larla aynı.
ARG VITE_API_URL=http://localhost:5090
ARG VITE_KEYCLOAK_URL=http://localhost:8080
ENV API_URL=$VITE_API_URL KEYCLOAK_URL=$VITE_KEYCLOAK_URL
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
COPY security-headers.inc.template /etc/nginx/templates/security-headers.inc.template
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
