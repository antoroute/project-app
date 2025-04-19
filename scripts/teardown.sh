#!/bin/bash
docker compose -f app/docker-compose-app.yml down
docker compose -f infrastructure/docker-compose-infra.yml down
