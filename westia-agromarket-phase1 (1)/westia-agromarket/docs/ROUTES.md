# Route structure (Phase 1 draft)

**Public**: `/` `/about` `/contact` `/faq` `/marketplace` `/marketplace/:categorySlug` `/products/:slug`
`/vendors/:slug` `/trade` `/trade/rfq/new` (login required to submit) `/login` `/register` `/forgot-password`

**Buyer** (`/buyer/*`): `dashboard` `orders` `orders/:id` `rfqs` `messages` `notifications` `account`
Checkout: `/cart` `/checkout` `/checkout/return`

**Farmer** (`/farmer/*`): `dashboard` `farms` `farms/:id` `plots` `crops` `activities` `expenses` `budgets`
`inventory` `harvests` `harvests/:id/list` (publish to marketplace)

**Vendor** (`/vendor/*`): `dashboard` `onboarding` `products` `products/new` `products/:id/edit` `orders`
`shipments` `earnings` `payouts` `subscription` `rfqs` `messages`

**Admin** (`/admin/*`): `dashboard` `users` `vendors` `moderation` `orders` `payments` `refunds`
`commissions` `payouts` `disputes` `reports` `audit-logs`

Route guards check role in the UI for navigation only; real enforcement is RLS and Edge Functions.
