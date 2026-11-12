# Cabeceras hacia los servicios. Se incluye en server {} y de nuevo en cada location que define
# sus propias proxy_set_header (NGINX no hereda ninguna si la location declara alguna).
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $forwarded_proto;
proxy_set_header X-Request-Id $correlation_id;
