# Transactional Outbox

In Tansu the storage engine is used to store the Kafka compatible broker meta and message data.
The same storage engine (database) can also store the business entities related to the messages.

In an online shop, we can check stock availability, whether the customer is of good standing **and**
produce a message to a topic to accept the order in a **single** transaction:

```sql
update stock
set quantity = quantity - order_request.quantity
from customer c
where
stock.product = order_request.product
and c.id = order_request.customer
and not(c.blocked)
and stock.quantity >= order_request.quantity;

if FOUND then
    -- enough stock and of good standing, accept the order:
    insert into order_status (order_request, status)
    values (new.id, 'accepted')
    returning order_status.ext_ref into ext_ref;
    
    -- produce a message to the order 'accept' topic:
    perform produce_message('accept', partition_num, null, format('{"ref": "%s"}');
else
    -- not enough stock, or of bad standing:
    insert into order_status (order_request, status)
    values (new.id, 'rejected');
end if;
```

The
[Transactional Outbox](https://microservices.io/patterns/data/transactional-outbox.html)
pattern is typically used where a command must atomically update the database and send messages
in order to avoid data inconsistencies and bugs.
In Tansu, updating a business entity and sending a message is just an `UPDATE` and `INSERT`
in a regular database transaction.
No other moving parts. No latency inducing service polling an `OUTBOX` table, to forward
messages to the broker that needs to be monitored 24x7.

Continuing with an online shop as an example. The products available are represented by the `product` table:

```sql
create table product (
    id int generated always as identity primary key,
    sku text not null,
    unique (sku),
    description text
);
```

Each `product` has an available `stock` quantity:

```sql
create table stock (
    id int generated always as identity primary key,
    product int references product(id) not null,
    quantity int
);
```

A `customer` is identified by their `email` and can only place orders from the shop if they are not `blocked`:

```sql
create table customer (
    id int generated always as identity primary key,
    email text not null,
    unique (email),
    blocked bool not null
);
```

An order is placed by producing a JSON message onto the `order` topic,
with the customer's `email`, the `sku` being ordered and the `quantity`:

```json
{"value": {"email": "a@b.com", "sku": "SK01", "quantity": 1}}
```

Tansu uses a `record` table to store messages that are produced to the broker.
The table is [partitioned](https://www.postgresql.org/docs/current/ddl-partitioning.html)
by `topic` and `partition` effectively making each a separate table.

An `order_request` represents the JSON message, with the `topic`, `partition`
and message `offset_id` referencing the original `record`:

```sql
create table order_request (
    id int generated always as identity primary key,
    topition int,
    offset_id bigint,
    foreign key (topition, offset_id) references record (topition, offset_id),
    customer int references customer(id),
    product int references product(id),
    quantity int
);
```

We can use a [trigger](https://www.postgresql.org/docs/18/sql-createtrigger.html) on the `record` table
to populate the `order_request` table as each record is inserted on the `accept` topic:

```sql
create or replace function on_tansu_record_insert() returns trigger as $$
declare
    topic_name text;
begin
    -- the topic_name of the message being inserted:
    select t.name into topic_name
    from topic t
    join topition tp on tp.topic = t.id
    where tp.id = new.topition;

    if topic_name = 'order' then
        declare
            order_email text;
            order_sku text;
            order_quantity int;
        begin
            -- extract the JSON message data
            order_email = json(new.v)->>'email';
            order_sku = json(new.v)->>'sku';
            order_quantity = (json(new.v)->>'quantity')::int;

            -- insert the extracted data into an order request
            insert into order_request (topition, offset_id, customer, product, quantity)
            select new.topition, new.offset_id, c.id, p.id, order_quantity
            from customer c, product p
            join stock s on s.product = p.id
            where c.email = order_email
            and p.sku = order_sku;
        end;
    end if;
    return new;
end;
$$ LANGUAGE plpgsql;
```

Adding the trigger to the Tansu `record` table:

```sql
create trigger tansu_record_insert
after insert on record
for each row execute function on_tansu_record_insert();
```

If there is a sufficient stock available for the `sku` **and** the customer is in good standing (not `blocked`),
a message will be produced on the `accept` topic containing a `ref` for the order:

```json
{"ref": "019bacac-2841-7982-998c-6a7b8d2d1ac4"}
```
If there is insufficient stock or the customer is not of good standing no message will be produced to the `accept` topic.

```sql
create or replace function on_order_request_insert() returns trigger as $$
begin
    -- accept the order if there is sufficient stock
    -- and the customer is of good standing
    update stock
    set quantity = quantity - new.quantity
    from customer c
    where
    stock.product = new.product
    and c.id = new.customer
    and not(c.blocked)
    and stock.quantity >= new.quantity;

    if FOUND then
        RAISE NOTICE 'order: accepted';

        declare
            partition_num int;
            ext_ref uuid;
        begin
            -- use the same partition on the 'accepted' topic:
            select tp.partition into partition_num
                from
                    topition tp
                where
                    tp.id = new.topition;

            -- accept the order creating a public order reference:
            insert into order_status (order_request, status)
            values (new.id, 'accepted')
            returning order_status.ext_ref into ext_ref;

            -- produce message to the 'accept' topic:
            perform tansu_produce_message('accept', partition_num, null, format('{"ref": "%s"}', ext_ref::text)::bytea);
        end;
    else
        insert into order_status (order_request, status)
        values (new.id, 'rejected');
    end if;
    return new;
end;
$$ LANGUAGE plpgsql;
```

Add the trigger on `INSERT` to the `order_request` table:

```sql
create trigger order_request_insert
after insert on order_request
for each row execute function on_order_request_insert();
```

This repository contains a working example of:

- the database schema outlined above for the `shop`
- some sample data, including a customers of good and bad standing
- triggers on the `record` and `order_request` tables
- a consumer using the [asyncio client for kafka](https://github.com/aio-libs/aiokafka) reading accepted orders from the `accept` topic

Prerequisites:
- **[docker](https://www.docker.com)**, using [compose.yaml](compose.yaml) which runs [tansu](https://tansu.io) and [PostgreSQL](https://www.postgresql.org)
- **[just](https://github.com/casey/just)**, a handy way to save and run project-specific commands
- **[uv](https://github.com/astral-sh/uv)**, an extremely fast Python package and project manager used to run the examples

[justfile](./justfile) contains recipes to run the example.

Once you have the prerequisites installed, clone this repository and start everything up with:

```shell
git clone git@github.com:tansu-io/example-pg-tx-outbox.git
cd example-pg-tx-outbox
```

To start [PostgreSQL](https://www.postgresql.org) and [tansu](https://tansu.io) running as docker contains:

```shell
just
```

Start the consumer on the `accept` topic with:

```shell
just consumer
```

In another shell, place an order with a customer of good standing:

```shell
just good-purchase
```

Over of the `consumer` shell you should see output similar to:

```shell
consumed:  accept 0 0 None b'{"ref": "019bad18-16a9-7e0e-b759-0b68d6566133"}' 1768135595686
```

Where `ref` is an order reference that can be given to the customer.
You can continue placing orders for the customer of good standing until the stock runs out (6 in total).
At that point, no further messages should be produced to the `accept` topic.

You can also place an order from a blocked customer with:

```shell
just blocked-purchase
```

There should be no output on the `accept` topic for that customer.

You can inspect the database using:

```shell
just psql
```

Want to try it out for yourself? Clone (and ⭐) Tansu at [https://github.com/tansu-io/tansu](https://github.com/tansu-io/tansu).
