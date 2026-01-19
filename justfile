[doc("bring tansu/pg up, create tansu topics")]
up: docker-compose-down docker-compose-up order-topic-create accept-topic-create

down: docker-compose-down

[private]
docker-compose-up *args:
    docker compose up --wait --detach {{ args }}

[private]
docker-compose-down *args:
    docker compose down --remove-orphans --volumes {{ args }}

[doc("ps")]
docker-compose-ps:
    docker compose ps

[private]
docker-compose-logs *args:
    docker compose logs {{ args }}

[doc("psql@postgres")]
psql *args:
    docker compose exec primary psql {{ args }}

[private]
psql-command sql *args:
    docker compose exec primary psql {{ args }} --command "{{ sql }}"

[private]
topic-create topic *args:
    docker compose exec tansu /tansu topic create {{ topic }} {{ args }}

[doc("list tansu topics")]
topic-list:
    docker compose exec tansu /tansu topic list | jq '.[].name'

[private]
order-topic-create *args: (topic-create "order_json" args) (topic-create "order_xml" args)

[private]
accept-topic-create *args: (topic-create "accepted_orders" args)

[doc("python produce to 'order_json' topic from a good standing customer")]
good-purchase-json:
    echo '{"value": {"email": "a@b.com", "sku": "SK01", "quantity": 1}}' | docker compose exec -T tansu /tansu cat produce order_json -

[doc("java produce to 'order_xml' topic from a good standing customer")]
good-purchase-xml:
    echo '<order><email>a@b.com</email><sku>SK01</sku><quantity>1</quantity></order>' | docker compose exec -T kafka  /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server tansu:9092 --topic order_xml

[doc("python producer purchase from a blocked customer")]
blocked-purchase-json:
    echo '{"value": {"email": "fraud@c.com", "sku": "SK01", "quantity": 1}}' | docker compose exec -T tansu /tansu cat produce order -

[doc("kafka producer purchase from a blocked customer")]
blocked-purchase-xml:
    echo '<order><email>fraud@c.com</email><sku>SK01</sku><quantity>1</quantity></order>' | docker compose exec -T kafka  /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server tansu:9092 --topic order_xml

[doc("list all customers")]
select-customer: (psql-command "select * from customer order by email")

[doc("list all order requests")]
select-order-request: (psql-command "select * from order_request")

[doc("status of all orders")]
select-order-status: (psql-command "select * from order_status")

[doc("list all products")]
select-product: (psql-command "select * from product order by sku")

[doc("list all stock")]
select-stock: (psql-command "select p.sku, s.quantity from product p join stock s on s.product = p.id order by p.sku")

[private]
primary-logs:
    docker compose logs primary

[doc("python consumer on 'accepted_orders' topic")]
consumer-python:
    uv run consumer.py

[doc("java consumer on 'accepted_orders' topic")]
consumer-java:
    docker compose exec kafka  /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server tansu:9092 --topic accepted_orders
