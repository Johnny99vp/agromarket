-- Westia Farm AgroMarket - Phase 1 revision: business decisions
-- 5% default commission, plan-based farmer/vendor access with 7-day trial,
-- seller-defined delivery options, NGN marketplace + NGN/USD RFQ quotes.
-- 0001 has not been deployed anywhere, so the old per-vendor subscription tables are replaced.
-- (Before first deploy these two files can be squashed into one.)

-- ===== Subscriptions: per USER (farmers have no vendor record) =====
drop table if exists vendor_subscriptions;
drop table if exists vendor_subscription_plans;

create table subscription_plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  role_scope text not null check (role_scope in ('both','single')),
  billing_interval text not null check (billing_interval in ('trial','monthly','yearly')),
  price_minor bigint not null check (price_minor >= 0),
  currency char(3) not null default 'NGN' check (currency = 'NGN'),
  interval_days int not null check (interval_days > 0),
  max_products int,
  active boolean not null default true
);

create table user_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  plan_id uuid not null references subscription_plans(id),
  status subscription_status not null default 'active',
  -- Only for single-role plans: which one the user chose.
  selected_role user_role check (selected_role in ('farmer','vendor')),
  current_period_start timestamptz not null default now(),
  current_period_end timestamptz not null,
  payment_id uuid,                              -- set when a paid plan; FK added below
  created_at timestamptz not null default now()
);
create index on user_subscriptions(user_id, status);
-- At most one active subscription per user.
create unique index one_active_subscription_per_user
  on user_subscriptions(user_id) where status = 'active';

-- Subscription payments reuse the payments table (Paystack), linked to a subscription instead of an order.
alter table payments alter column order_id drop not null;
alter table payments add column subscription_id uuid references user_subscriptions(id);
alter table payments add constraint payment_has_one_target
  check ((order_id is not null)::int + (subscription_id is not null)::int = 1);
alter table user_subscriptions add constraint user_subscriptions_payment_fk
  foreign key (payment_id) references payments(id);

-- One free 1-week trial per user, granting both roles.
alter table profiles add column trial_used_at timestamptz;

insert into subscription_plans (code, name, role_scope, billing_interval, price_minor, interval_days) values
  ('trial',               'Free trial (1 week, farmer + vendor)', 'both',   'trial',    0,        7),
  ('both_monthly',        'Farmer + Vendor, monthly',             'both',   'monthly',  1200000,  30),
  ('both_yearly',         'Farmer + Vendor, yearly',              'both',   'yearly',   12000000, 365),
  ('single_monthly',      'Farmer or Vendor, monthly',            'single', 'monthly',  500000,   30),
  ('single_yearly',       'Farmer or Vendor, yearly',             'single', 'yearly',   5000000,  365);

-- Server-only: starts the trial. Execution is not granted to client roles (see end of file).
create or replace function start_trial(_user uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare _plan uuid; _sub uuid;
begin
  if (select trial_used_at from profiles where id = _user) is not null then
    raise exception 'Trial already used';
  end if;
  select id into _plan from subscription_plans where code = 'trial';
  insert into user_subscriptions (user_id, plan_id, current_period_end)
    values (_user, _plan, now() + interval '7 days') returning id into _sub;
  update profiles set trial_used_at = now() where id = _user;
  return _sub;
end $$;

-- Does this user currently have working access to a role's features?
-- Buyers and admins need no plan. Farmer/vendor need the role AND an unexpired plan covering it.
create or replace function has_active_access(_user uuid, _role user_role) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare _scope text; _selected user_role;
begin
  if not has_role(_user, _role) then return false; end if;
  if _role in ('buyer','admin') then return true; end if;
  select p.role_scope, s.selected_role into _scope, _selected
    from user_subscriptions s join subscription_plans p on p.id = s.plan_id
   where s.user_id = _user and s.status = 'active' and s.current_period_end > now()
   order by s.current_period_end desc limit 1;
  if not found then return false; end if;
  return _scope = 'both' or _selected = _role;
end $$;

-- ===== Commission: 5% platform default =====
insert into commission_rules (category_id, rate_bps) values (null, 500);
-- Applies to product line totals only; delivery fees are not commissioned (assumption, see DECISIONS.md).

-- ===== Delivery: seller defines options, buyer chooses =====
alter table products add column unit_weight_kg numeric(10,3) check (unit_weight_kg > 0);

create table delivery_options (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id) on delete cascade,
  name text not null,
  method text not null check (method in ('flat','per_weight','negotiated')),
  flat_fee_minor bigint check (flat_fee_minor >= 0),
  per_kg_fee_minor bigint check (per_kg_fee_minor >= 0),
  min_fee_minor bigint not null default 0 check (min_fee_minor >= 0),
  regions text[],                                -- null = all of Nigeria
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (method <> 'flat'       or flat_fee_minor is not null),
  check (method <> 'per_weight' or per_kg_fee_minor is not null)
);
create index on delivery_options(vendor_id, active);

-- One row per vendor in an order (multi-vendor carts ship separately). Fee is computed server-side.
create table order_delivery_selections (
  order_id uuid not null references orders(id) on delete cascade,
  vendor_id uuid not null references vendors(id),
  delivery_option_id uuid not null references delivery_options(id),
  method text not null,
  fee_minor bigint not null default 0 check (fee_minor >= 0),
  -- negotiated: vendor sets the fee, buyer must accept before payment.
  quote_status text not null default 'not_required'
    check (quote_status in ('not_required','awaiting_vendor','quoted','accepted','declined')),
  primary key (order_id, vendor_id)
);

-- ===== Currency: marketplace is NGN; RFQ/export quotes may be NGN or USD =====
alter table products  add constraint products_ngn_only  check (currency = 'NGN');
alter table orders    add constraint orders_ngn_only    check (currency = 'NGN');
alter table payments  add constraint payments_ngn_only  check (currency = 'NGN');
alter table rfq_quotes add constraint rfq_quote_currency check (currency in ('NGN','USD'));

-- ===== RLS: deny by default on the new tables =====
alter table subscription_plans         enable row level security;
alter table user_subscriptions         enable row level security;
alter table delivery_options           enable row level security;
alter table order_delivery_selections  enable row level security;

-- Privileged functions must not be callable by browser users.
revoke execute on function start_trial(uuid) from public, anon, authenticated;
