# Architecture (Phase 1 for review)

## Style
Modular monolith. One React SPA, one Supabase project (Postgres + Auth + Storage + Edge Functions),
one shared package for types/validation. No microservices; a separate Node service is added only if a
job cannot run in an Edge Function.

## Layers and rules
1. **Browser (apps/web)**: UI only. Talks to Supabase through `src/services/*` modules; components never
   call `supabase.from()` directly. Holds the publishable key only.
2. **Postgres + RLS**: first line of defence. Every table has RLS enabled; no policy = no access.
   Users read and write only rows they own, via policies written per phase and tested.
3. **Edge Functions (server)**: everything involving money, stock, roles, or other users' data. Holds the
   service-role key and Paystack secret. Validates input with Zod. Never trusts client-supplied prices,
   totals, roles, or payment status.
4. **Database functions (RPC)**: multi-step writes (reserve stock, finalise payment) run as one
   transaction inside Postgres.

## Key decisions
| Topic | Decision | Reason |
|---|---|---|
| Money | integer minor units (kobo), `currency` column on each amount | no float rounding errors |
| Roles | separate `user_roles` table, `has_role()` security-definer function | users cannot edit their own role |
| Admin | never self-assignable; granted only by service role | prevents privilege escalation |
| History | `ledger_entries`, `stock_movements`, `audit_logs` are append-only (trigger blocks update/delete) | no silent overwrite of financial history |
| Order prices | `order_items` snapshot name, price, commission rate at purchase | later price edits do not change past orders |
| Stock | reserve on checkout with expiry; consume on payment success; release on expiry/failure | prevents overselling |
| Idempotency | `orders(buyer_id, idempotency_key)` unique; `webhook_events(provider, event_id)` unique; `payments.reference` unique | safe retries and replayed webhooks |

## Paystack payment flow (all server-side)
1. Buyer submits cart -> Edge Function `checkout-initialize`: re-reads prices and stock from the DB,
   creates order + order_items + reservations in one transaction, inserts `payments` row (status `initiated`,
   server-generated reference), calls Paystack Initialize with the secret key, returns `authorization_url`.
2. Buyer pays on Paystack, returns to `/checkout/return?reference=...`. The page only asks the server
   `payment-verify`; the browser's opinion of the result is ignored.
3. `paystack-webhook` Edge Function: verify `x-paystack-signature` (HMAC-SHA512 of raw body with the secret key),
   insert into `webhook_events` (duplicate = ignore), call Paystack Verify, confirm amount and currency equal
   the stored payment, then run `finalize_payment()` in one transaction: payment -> success, order -> paid,
   reservations -> consumed, stock movements written, ledger entries (cash, commission, vendor earnings) written.
4. Refunds: admin-only function calls Paystack Refund, records `refunds` row and reversing ledger entries.
5. Payouts: Phase 6 records payouts and vendor balances from the ledger. Automated Paystack Transfers
   need a verified Paystack business account, so initial payouts are admin-approved records.

## Farm-to-marketplace
A farmer's `harvest_records` row can be listed as a product (`products.source_harvest_id`). Listing increments
`quantity_listed` and writes a `stock_movements` row in one transaction; a check constraint prevents listing more
than was harvested. Farm Manager (westiafarm.bolt.host) is integrated only if its owner supplies a documented,
authorized API; until then AgroMarket's own farm module is the only source. No endpoints are assumed.

## Folder structure
```
apps/web/src/{components,pages,layouts,routes,services,hooks,lib,types}
supabase/migrations   supabase/functions/{checkout-initialize,payment-verify,paystack-webhook,...}
packages/shared/src   docs/
```

## Implementation plan
| Phase | Scope | Exit check |
|---|---|---|
| 1 | this document set, schema | you approve the design; migration applies cleanly on a local DB |
| 2 | Vite app, auth, roles, route guards, RLS for identity tables | RLS tests: user A cannot read user B |
| 3 | vendors, products, storage, moderation, public marketplace | vendor edits only own products |
| 4 | farm module + RLS | farmer sees only own farm data |
| 5 | harvest -> listing sync, Farm Manager adapter (if API provided) | stock never negative |
| 6 | cart, checkout, Paystack, ledger, refunds, commissions, subscriptions | forged payment status ignored; replayed webhook ignored |
| 7 | shipments, messaging, notifications, reviews, disputes, RFQ | users see only own conversations |
| 8 | admin, audit, BACKEND_REVIEW.md, API docs, test report, deploy guides | admin endpoints reject non-admins |

## Decisions
Owner decisions on commission, subscriptions, currency, delivery and roles are recorded in `DECISIONS.md` and implemented in migration `0002_business_rules.sql`.
