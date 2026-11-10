# Produção na EC2. O nginx do host publica o domínio; o container escuta só em localhost.
# No servidor: make setup && make start

DOCKER_COMPOSE ?= $(shell \
	docker compose version >/dev/null 2>&1 \
	&& echo docker compose \
	|| echo docker-compose \
)

COMPOSE = -f docker-compose.prod.yml
DOMAIN ?= freellmapi.essentjus.com.br

.PHONY: setup start stop restart

setup:
	@test -f .env || (echo "Falta o .env na raiz. Coloque ENCRYPTION_KEY, TRUST_PROXY, ALLOWED_HOSTS, HOST_BIND e PORT." && exit 1)
	@grep -Eq '^ENCRYPTION_KEY=[0-9a-fA-F]{64}$$' .env || (echo "ENCRYPTION_KEY precisa ter 64 caracteres hex. Gere com: openssl rand -hex 32" && exit 1)
	@command -v docker >/dev/null 2>&1 || (echo "Docker não encontrado." && exit 1)
	chmod +x scripts/install-nginx.sh
	sudo ./scripts/install-nginx.sh $(DOMAIN)

start:
	$(DOCKER_COMPOSE) $(COMPOSE) up -d --build

stop:
	$(DOCKER_COMPOSE) $(COMPOSE) down

restart: stop start
