# Her server'da: oauth2-proxy'nin adresleri (/oauth2/start, /oauth2/callback, /oauth2/sign_out) ve isteğin geçip
# geçmeyeceğini soran /oauth2/auth. oauth2-proxy dönüş adresini (redirect_uri) isteğin geldiği adresten kurar.
server_tokens off;

location /oauth2/ {
    proxy_pass http://oauth2-proxy:4180;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Uri $request_uri;
}

# auth_request'in sorduğu adres: 202 geç, 401 oturum ya da geçerli token yok, 403 rol yok. Gövde gönderilmez.
location = /oauth2/auth {
    proxy_pass http://oauth2-proxy:4180;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Uri $request_uri;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
}
