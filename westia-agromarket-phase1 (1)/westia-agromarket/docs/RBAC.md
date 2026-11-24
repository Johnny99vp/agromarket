# Role and permission matrix (Phase 1 draft)

Roles: **buyer**, **farmer**, **vendor**, **admin**. A user may hold several (e.g. farmer + vendor).
Self-signup can grant buyer, farmer or vendor only. Admin is granted server-side.
"Own" = rows linked to the user's id. "Server" = performed by an Edge Function, not direct table access.

| Resource | Anonymous | Buyer | Farmer | Vendor | Admin |
|---|---|---|---|---|---|
| Public products, categories, approved vendor storefronts | read | read | read | read | read |
| Own profile | - | read/update | read/update | read/update | read/update |
| Other users' profiles | - | no | no | no | read |
| User roles | - | no | no | no | manage (server) |
| Farms, plots, crops, activities, expenses, budgets, inventory, harvests | - | no | own CRUD | own CRUD if also farmer | read (support), no edit |
| Vendor profile and documents | - | create own application | no | own read/update | approve/reject/suspend (server) |
| Products | active only | read | read | own CRUD (go to review) | moderate/approve/reject (server) |
| Cart | - | own CRUD | own CRUD | own CRUD | no |
| Orders | - | create (server), read own | same | read orders containing own items | read all |
| Payments, refunds | - | read own | read own | no | read all; refund (server) |
| Ledger, commissions, payouts | - | no | no | read own earnings/payouts | read all; approve payouts (server) |
| Subscriptions | - | no | no | own read/purchase (server) | manage plans |
| Shipments | - | read own order's | read own | update own shipments | read all |
| Messages, notifications | - | own conversations | own | own | no (disputes only, audited) |
| Reviews | read | create for own completed purchase | same | read on own products | moderate |
| Disputes | - | open/read own | own | respond on own orders | resolve (server) |
| RFQs and quotes | - | create/read own RFQ | no | quote on open RFQs, read own quotes | read all |
| Audit logs | - | no | no | no | read |

Hard rules: no client-side writes to `payments`, `ledger_entries`, `refunds`, `payouts`, `user_roles`,
`stock_movements`, `webhook_events` or `audit_logs`. Those are written only by server code.
