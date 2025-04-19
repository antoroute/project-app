up:
	docker compose -f docker-compose-app.yml up -d --build
down:
	docker compose -f docker-compose-app.yml down
restart:
	make down && make up
logs:
	docker compose -f docker-compose-app.yml logs -f