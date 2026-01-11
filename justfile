up: docker-compose-down docker-compose-up order-topic-create accept-topic-create

docker-compose-up *args:
    docker compose up --wait --detach {{ args }}

docker-compose-down *args:
    docker compose down --remove-orphans --volumes {{ args }}

docker-compose-ps:
    docker compose ps

docker-compose-logs *args:
    docker compose logs {{ args }}

psql *args:
    docker compose exec primary psql {{ args }}

topic-create topic *args:
    docker compose exec tansu /tansu topic create {{ topic }} {{ args }}

topic-list:
    docker compose exec tansu /tansu topic list | jq '.[].name'

order-topic-create *args: (topic-create "order" args)

accept-topic-create *args: (topic-create "accept" args)

good-purchase:
    #!/usr/bin/env zsh
    echo '{"value": {"email": "a@b.com", "sku": "SK01", "quantity": 1}}' | docker compose exec -T tansu /tansu cat produce order -

blocked-purchase:
    #!/usr/bin/env zsh
    echo '{"value": {"email": "fraud@c.com", "sku": "SK01", "quantity": 1}}' | docker compose exec -T tansu /tansu cat produce order -

consumer:
    uv run consumer.py
