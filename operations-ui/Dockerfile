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
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
