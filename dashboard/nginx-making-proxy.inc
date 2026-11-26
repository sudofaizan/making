# MAKING dashboard locations — include inside server {} (xauusd-bar-routes.inc). Upstream is inline (host:8877 via docker bridge).
location = /making {
    return 301 /making/;
}

location /making/ {
    proxy_pass http://172.17.0.1:8877/;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_connect_timeout 10s;
    proxy_read_timeout 120s;
    client_max_body_size 512k;
}