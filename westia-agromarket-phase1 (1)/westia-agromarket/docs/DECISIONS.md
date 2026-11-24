# Business decisions (confirmed by owner) and how the design implements them

| Decision | Implementation |
|---|---|
| 5% general commission | `commission_rules` default row = 500 bps. Rate is copied onto each `order_items` row at purchase so later changes never alter past orders. |
| 1-week free trial | One per user (`profiles.trial_used_at`), grants both farmer and vendor access. Started only by the server (`start_trial`). |
| Farmer + Vendor plan | NGN 12,000/month (`both_monthly`) or NGN 120,000/year (`both_yearly`). |
| Single-role plan | NGN 5,000/month (`single_monthly`) or NGN 50,000/year (`single_yearly`). User picks farmer OR vendor (`user_subscriptions.selected_role`). |
| Access follows the plan | `has_active_access(user, role)` = holds the role AND has an unexpired plan covering it. Buyers need no plan. RLS policies in Phase 2+ for farm and vendor tables will call it. |
| NGN plus RFQ/export | Products, orders and payments are NGN only. RFQ quotes may be NGN or USD. |
| Delivery set by seller, buyer chooses | Vendors define `delivery_options` of three types: `flat`, `per_weight` (needs `products.unit_weight_kg`), `negotiated` (vendor quotes, buyer accepts before paying). Buyer picks one per vendor; the server computes the fee. |
| One account, both roles | `user_roles` allows several roles per user; plan decides what is usable. |

## Assumptions I made - please confirm or correct
1. The trial gives access to both farmer and vendor features.
2. "Just one tier" was read as two plans: one for both roles and one for a single role, each monthly or yearly.
3. Commission applies to product totals only, not delivery fees or subscription fees.
4. "Vendor-set" delivery was read as a negotiated quote, since flat and per-weight are already set by the vendor.
5. When a paid plan expires, the user keeps read access to their own data but cannot add or edit farm or vendor records, and their products are hidden from the marketplace.
6. USD is used only for RFQ/export quotes. Paystack USD checkout needs separate enablement on your Paystack account, so it is not planned for the first release.
