# Aracın kendisine giden her istek: önce oauth2-proxy'ye sorulur. Oturum yoksa (401) giriş başlatılır; giriş bitince
# istenen adrese dönülür. Tarayıcıda rolü olmayan kullanıcıya oauth2-proxy 403 sayfası gösterir; rolü olmayan token 401
# sayılır ve girişe yönlendirilir.
auth_request /oauth2/auth;
error_page 401 =302 /oauth2/start?rd=$scheme://$http_host$request_uri;

proxy_set_header Host $http_host;

# Alertmanager her origin'e (Access-Control-Allow-Origin: *), Prometheus isteğin origin'ine izin veriyor: başka bir sitenin
# sayfası kullanıcının tarayıcısıyla bu adreslere istek atıp cevabı okuyamasın diye bu başlıklar cevaptan silinir. Araçların
# kendi arayüzleri aynı adresten çalıştığı için CORS'a ihtiyaç duymaz.
proxy_hide_header Access-Control-Allow-Origin;
proxy_hide_header Access-Control-Allow-Methods;
proxy_hide_header Access-Control-Allow-Headers;
proxy_hide_header Access-Control-Allow-Credentials;
proxy_hide_header Access-Control-Expose-Headers;
proxy_hide_header Access-Control-Max-Age;
