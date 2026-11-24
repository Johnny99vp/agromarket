-- Westia Farm AgroMarket - Phase 1 core schema
-- Money is stored as integer minor units (kobo for NGN). Never floats.
-- RLS is ENABLED on every table here with NO policies = deny by default.
-- Policies are added in Phase 2+ migrations. Server-side functions use the service role.

create extension if not exists pgcrypto;
create extension if not exists citext;

-- ===== Enums =====
create type user_role as enum ('buyer','farmer','vendor','admin');
create type account_status as enum ('active','suspended');
create type vendor_status as enum ('pending','approved','rejected','suspended');
create type product_status as enum ('draft','pending_review','active','rejected','archived');
create type order_status as enum ('pending_payment','paid','processing','shipped','delivered','completed','cancelled','refunded');
create type payment_status as enum ('initiated','success','failed','abandoned');
create type reservation_status as enum ('active','consumed','released','expired');
create type refund_status as enum ('pending','processed','failed');
create type ledger_account as enum ('platform_commission','vendor_earnings','vendor_payable','platform_cash','refund_liability');
create type payout_status as enum ('pending','processing','paid','failed');
create type shipment_status as enum ('pending','picked_up','in_transit','delivered','failed','returned');
create type dispute_status as enum ('open','under_review','resolved_buyer','resolved_vendor','closed');
create type rfq_status as enum ('open','quoted','accepted','closed','expired');
create type subscription_status as enum ('active','past_due','cancelled','expired');

-- ===== Helpers =====
create or replace function set_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

create or replace function forbid_mutation() returns trigger language plpgsql as $$
begin raise exception 'Table % is append-only', tg_table_name; end $$;

-- ===== Identity =====
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null default '',
  phone text,
  country text not null default 'NG',
  avatar_url text,
  status account_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Roles live in their own table so users can never edit their own role via profiles.
-- Only the server (service role) may grant admin; self-signup may only get buyer/farmer/vendor.
create table user_roles (
  user_id uuid not null references profiles(id) on delete cascade,
  role user_role not null,
  granted_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create or replace function has_role(_user uuid, _role user_role) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles where user_id = _user and role = _role)
$$;

-- ===== Vendors & catalogue =====
create table vendors (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles(id),
  business_name text not null,
  slug citext not null unique,
  description text,
  country text not null default 'NG',
  status vendor_status not null default 'pending',
  verified_at timestamptz,
  verified_by uuid references profiles(id),
  rejection_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on vendors(owner_id);

create table vendor_documents (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id) on delete cascade,
  doc_type text not null,
  storage_path text not null,
  created_at timestamptz not null default now()
);

create table categories (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references categories(id),
  name text not null,
  slug citext not null unique,
  sort_order int not null default 0
);

create table products (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  category_id uuid references categories(id),
  name text not null,
  slug citext not null unique,
  description text,
  unit text not null,                       -- kg, bag, crate, tonne ...
  price_minor bigint not null check (price_minor >= 0),
  currency char(3) not null default 'NGN',
  min_order_qty numeric(12,3) not null default 1 check (min_order_qty > 0),
  stock_quantity numeric(12,3) not null default 0 check (stock_quantity >= 0),
  status product_status not null default 'draft',
  moderation_note text,
  source_harvest_id uuid,                   -- FK added after harvest_records exists
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on products(vendor_id);
create index on products(category_id, status);

create table product_images (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete cascade,
  storage_path text not null,
  sort_order int not null default 0
);

-- Every stock change is recorded; products.stock_quantity is the cached result.
create table stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id),
  delta numeric(12,3) not null,
  reason text not null,                     -- restock, sale, reservation_release, adjustment, harvest_sync
  ref_type text,
  ref_id uuid,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create trigger stock_movements_append_only before update or delete on stock_movements
  for each row execute function forbid_mutation();

-- ===== Farm management =====
create table farms (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references profiles(id),
  name text not null,
  location text,
  country text not null default 'NG',
  size_hectares numeric(12,3),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on farms(owner_id);

create table plots (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  name text not null,
  size_hectares numeric(12,3),
  soil_type text,
  created_at timestamptz not null default now()
);

create table crop_cycles (
  id uuid primary key default gen_random_uuid(),
  plot_id uuid not null references plots(id) on delete cascade,
  crop_name text not null,
  planted_on date,
  expected_harvest_on date,
  status text not null default 'growing',
  created_at timestamptz not null default now()
);

create table farm_activities (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  plot_id uuid references plots(id) on delete set null,
  crop_cycle_id uuid references crop_cycles(id) on delete set null,
  activity_type text not null,              -- planting, fertilising, spraying, weeding ...
  performed_on date not null,
  notes text,
  created_at timestamptz not null default now()
);

create table farm_budgets (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  crop_cycle_id uuid references crop_cycles(id) on delete set null,
  label text not null,
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null default 'NGN',
  created_at timestamptz not null default now()
);

create table farm_expenses (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  crop_cycle_id uuid references crop_cycles(id) on delete set null,
  category text not null,
  amount_minor bigint not null check (amount_minor >= 0),
  currency char(3) not null default 'NGN',
  spent_on date not null,
  notes text,
  created_at timestamptz not null default now()
);

create table farm_inventory_items (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  name text not null,
  item_type text not null,                  -- input, equipment, produce
  quantity numeric(12,3) not null default 0 check (quantity >= 0),
  unit text not null,
  updated_at timestamptz not null default now()
);

create table harvest_records (
  id uuid primary key default gen_random_uuid(),
  farm_id uuid not null references farms(id) on delete cascade,
  crop_cycle_id uuid references crop_cycles(id) on delete set null,
  crop_name text not null,
  quantity numeric(12,3) not null check (quantity > 0),
  unit text not null,
  harvested_on date not null,
  quantity_listed numeric(12,3) not null default 0 check (quantity_listed >= 0),
  created_at timestamptz not null default now(),
  check (quantity_listed <= quantity)
);
alter table products add constraint products_harvest_fk
  foreign key (source_harvest_id) references harvest_records(id);

-- ===== Cart & orders =====
create table carts (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null unique references profiles(id) on delete cascade,
  updated_at timestamptz not null default now()
);
create table cart_items (
  cart_id uuid not null references carts(id) on delete cascade,
  product_id uuid not null references products(id),
  quantity numeric(12,3) not null check (quantity > 0),
  primary key (cart_id, product_id)
);

create table orders (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references profiles(id),
  status order_status not null default 'pending_payment',
  subtotal_minor bigint not null check (subtotal_minor >= 0),
  delivery_fee_minor bigint not null default 0 check (delivery_fee_minor >= 0),
  total_minor bigint not null check (total_minor >= 0),
  currency char(3) not null default 'NGN',
  shipping_address jsonb not null,
  idempotency_key text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (buyer_id, idempotency_key),
  check (total_minor = subtotal_minor + delivery_fee_minor)
);
create index on orders(buyer_id);

create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  product_id uuid not null references products(id),
  vendor_id uuid not null references vendors(id),
  product_name text not null,               -- snapshot at purchase
  quantity numeric(12,3) not null check (quantity > 0),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  line_total_minor bigint not null check (line_total_minor >= 0),
  commission_rate_bps int not null check (commission_rate_bps between 0 and 10000),
  fulfilment_status order_status not null default 'pending_payment'
);
create index on order_items(order_id);
create index on order_items(vendor_id);

create table stock_reservations (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  product_id uuid not null references products(id),
  quantity numeric(12,3) not null check (quantity > 0),
  status reservation_status not null default 'active',
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index on stock_reservations(status, expires_at);

-- ===== Payments & money (append-only history) =====
create table payments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id),
  provider text not null default 'paystack',
  reference text not null unique,           -- generated server-side
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null default 'NGN',
  status payment_status not null default 'initiated',
  verified_at timestamptz,
  provider_response jsonb,
  created_at timestamptz not null default now()
);

-- Idempotency + audit of every webhook delivery
create table webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  event_id text not null,
  event_type text not null,
  payload jsonb not null,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (provider, event_id)
);

create table refunds (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references payments(id),
  order_id uuid not null references orders(id),
  amount_minor bigint not null check (amount_minor > 0),
  reason text,
  status refund_status not null default 'pending',
  provider_reference text,
  requested_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table commission_rules (
  id uuid primary key default gen_random_uuid(),
  category_id uuid references categories(id),   -- null = platform default
  rate_bps int not null check (rate_bps between 0 and 10000),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Double-entry style: each business event writes balanced rows sharing a txn_id.
create table ledger_entries (
  id uuid primary key default gen_random_uuid(),
  txn_id uuid not null,
  account ledger_account not null,
  owner_id uuid,                             -- vendor id for vendor accounts
  direction text not null check (direction in ('debit','credit')),
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null default 'NGN',
  ref_type text not null,                    -- payment, refund, payout, commission
  ref_id uuid not null,
  created_at timestamptz not null default now()
);
create index on ledger_entries(txn_id);
create index on ledger_entries(account, owner_id);
create trigger ledger_append_only before update or delete on ledger_entries
  for each row execute function forbid_mutation();

create table vendor_subscription_plans (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  price_minor bigint not null check (price_minor >= 0),
  interval_days int not null default 30,
  max_products int,
  active boolean not null default true
);
create table vendor_subscriptions (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  plan_id uuid not null references vendor_subscription_plans(id),
  status subscription_status not null default 'active',
  current_period_end timestamptz not null,
  created_at timestamptz not null default now()
);

create table payouts (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id),
  amount_minor bigint not null check (amount_minor > 0),
  currency char(3) not null default 'NGN',
  status payout_status not null default 'pending',
  provider_reference text,
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

-- ===== Logistics =====
create table shipments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id),
  vendor_id uuid not null references vendors(id),
  carrier text,
  tracking_code text,
  status shipment_status not null default 'pending',
  created_at timestamptz not null default now()
);
create table shipment_events (
  id uuid primary key default gen_random_uuid(),
  shipment_id uuid not null references shipments(id) on delete cascade,
  status shipment_status not null,
  note text,
  created_at timestamptz not null default now()
);

-- ===== Messaging, notifications, trust =====
create table conversations (
  id uuid primary key default gen_random_uuid(),
  subject text,
  created_at timestamptz not null default now()
);
create table conversation_participants (
  conversation_id uuid not null references conversations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  primary key (conversation_id, user_id)
);
create table messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null references profiles(id),
  body text not null,
  created_at timestamptz not null default now()
);
create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  type text not null,
  title text not null,
  body text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index on notifications(user_id, read_at);

create table reviews (
  id uuid primary key default gen_random_uuid(),
  order_item_id uuid not null unique references order_items(id),
  buyer_id uuid not null references profiles(id),
  product_id uuid not null references products(id),
  rating int not null check (rating between 1 and 5),
  comment text,
  created_at timestamptz not null default now()
);
create table disputes (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id),
  opened_by uuid not null references profiles(id),
  reason text not null,
  status dispute_status not null default 'open',
  resolution_note text,
  created_at timestamptz not null default now()
);

-- ===== International trade / RFQ =====
create table rfqs (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references profiles(id),
  commodity text not null,
  quantity numeric(14,3) not null check (quantity > 0),
  unit text not null,
  destination_country char(2) not null,
  incoterm text,
  needed_by date,
  notes text,
  status rfq_status not null default 'open',
  created_at timestamptz not null default now()
);
create table rfq_quotes (
  id uuid primary key default gen_random_uuid(),
  rfq_id uuid not null references rfqs(id) on delete cascade,
  vendor_id uuid not null references vendors(id),
  unit_price_minor bigint not null check (unit_price_minor >= 0),
  currency char(3) not null,
  lead_time_days int,
  notes text,
  created_at timestamptz not null default now()
);

-- ===== Audit =====
create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references profiles(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  details jsonb,
  created_at timestamptz not null default now()
);
create trigger audit_append_only before update or delete on audit_logs
  for each row execute function forbid_mutation();

-- ===== updated_at triggers =====
do $$
declare t text;
begin
  foreach t in array array['profiles','vendors','products','farms','orders','farm_inventory_items'] loop
    execute format('create trigger %I_updated before update on %I for each row execute function set_updated_at()', t, t);
  end loop;
end $$;

-- ===== Deny-by-default: enable RLS on every table =====
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', r.tablename);
  end loop;
end $$;
