-- -*- mode: sql; sql-product: postgres; -*-
-- Copyright (c) 2023-2026 Peter Morgan <peter.james.morgan@gmail.com>
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
-- http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

begin;

-- products that are available on the shop
--
create table product (
    id int generated always as identity primary key,
    sku text not null,
    unique (sku),
    description text
);

-- stock level of product available for sale
--
create table stock (
    id int generated always as identity primary key,
    product int references product(id) not null,
    quantity int
);

-- registered customer
-- blocked: indicates that the customer cannot place orders
--
create table customer (
    id int generated always as identity primary key,
    email text not null,
    unique (email),
    blocked bool not null
);

-- an order request that has come from the "order" tansu topic
--
create table order_request (
    id int generated always as identity primary key,
    topition int,
    offset_id bigint,
    foreign key (topition, offset_id) references record (topition, offset_id),
    customer int references customer(id),
    product int references product(id),
    quantity int
);

create table order_status (
    id int generated always as identity primary key,
    order_request int references order_request(id),
    ext_ref uuid default uuidv7(),
    unique (ext_ref),
    status text
);

-- products available for sale in shop
--
insert into product (sku, description) values ('SK01', 'Shoe');
insert into product (sku, description) values ('SK02', 'Sock');

-- stock levels
--
insert into stock (product, quantity)
select product.id, 6 from product where sku = 'SK01';

insert into stock (product, quantity)
select product.id, 3 from product where sku = 'SK02';

-- customers
--
insert into customer (email, blocked) values ('a@b.com', false);
insert into customer (email, blocked) values ('fraud@c.com', true);


create or replace function on_tansu_record_insert() returns trigger as $$
declare
    topic_name text;
begin
    select t.name into topic_name
    from topic t
    join topition tp on tp.topic = t.id
    where tp.id = new.topition;

    if topic_name = 'order_json' then
        declare
            order_email text;
            order_sku text;
            order_quantity int;
        begin
            order_email = json(new.v)->>'email';
            order_sku = json(new.v)->>'sku';
            order_quantity = (json(new.v)->>'quantity')::int;

            RAISE NOTICE 'order, from: %, sku: %, quantity: %', order_email, order_sku, order_quantity;

            insert into order_request (topition, offset_id, customer, product, quantity)
            select new.topition, new.offset_id, c.id, p.id, order_quantity
            from customer c, product p
            join stock s on s.product = p.id
            where c.email = order_email
            and p.sku = order_sku;
        end;
    elsif topic_name = 'order_xml' then
        declare
            document xml;
            order_email text;
            order_sku text;
            order_quantity int;
        begin
            document = xmlparse (content convert_from(new.v, 'utf-8'));
            order_email = (xpath('order/email/text()', document))[1];
            order_sku = (xpath('order/sku/text()', document))[1];
            order_quantity = (xpath('number(order/quantity/text())', document))[1]::text::int;

            RAISE NOTICE 'order, from: %, sku: %, quantity: %', order_email, order_sku, order_quantity;

            insert into order_request (topition, offset_id, customer, product, quantity)
            select new.topition, new.offset_id, c.id, p.id, order_quantity
            from customer c, product p
            join stock s on s.product = p.id
            where c.email = order_email
            and p.sku = order_sku;
        end;
    else
        raise notice 'ignored, topic: %, k: %, v: %', topic_name, new.k, new.v;
    end if;
    return new;
end;
$$ LANGUAGE plpgsql;


create function tansu_produce_message(topic_name text, partition_num int, k bytea, v bytea) returns bigint as $$
declare
    current_watermark watermark%ROWTYPE;
    updated_low bigint;
    updated_high bigint;
    offset_id bigint;
begin
    select w.* into current_watermark
    from topic t
    join topition tp on tp.topic = t.id
    join watermark w on w.topition = tp.id
    where
        t.name = topic_name
        and tp.partition = partition_num;

    raise notice 'topic: %, partition: %, found: %, current_watermark: %', topic_name, partition_num, found, current_watermark;

    if current_watermark.high is null then
        offset_id := 0;
        updated_high := 1;
    else
        offset_id := current_watermark.high;
        updated_high := current_watermark.high + 1;
    end if;

    if current_watermark.low is null then
        updated_low := 0;
    else
        updated_low := current_watermark.low;
    end if;

    RAISE NOTICE 'offset: %, low: %, high: %', offset_id, updated_low, updated_high;

    update watermark
    set
        low = updated_low,
        high = updated_high
    from
        topic t
        join topition tp on tp.topic = t.id
    where
        t.name = topic_name
        and tp.partition = partition_num
        and watermark.topition = tp.id;

    insert into record (topition, offset_id, attributes, timestamp, k, v)
    select tp.id, offset_id, 0, current_timestamp, k, v
    from topic t
    join topition tp on tp.topic = t.id
    where
        t.name = topic_name
        and tp.partition = partition_num;

    return offset_id;
end;
$$ language plpgsql;


create or replace function on_order_request_insert() returns trigger as $$
begin
    raise notice 'quantity: %, product: %, id: %', new.quantity, new.product, new.id;

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

            RAISE NOTICE 'ext_ref: %', ext_ref;
            perform tansu_produce_message('accepted_orders', partition_num, null, format('{"ref": "%s"}', ext_ref::text)::bytea);
        end;
    else
        RAISE NOTICE 'order: rejected';

        insert into order_status (order_request, status)
        values (new.id, 'rejected');
    end if;
    return new;
end;
$$ LANGUAGE plpgsql;


create trigger tansu_record_insert
after insert on record
    for each row execute function on_tansu_record_insert();

create trigger order_request_insert
after insert on order_request
    for each row execute function on_order_request_insert();

commit;
