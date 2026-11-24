# Westia Farm AgroMarket

Independent multi-vendor agricultural marketplace (launch market: Nigeria). Separate from the
corporate site (westiafarm.vercel.app) and the Farm Manager (westiafarm.bolt.host), which are not modified.

**Status: Phase 1 (architecture and database design) - revised with owner decisions, awaiting final approval. No application code yet.**

## Layout
- `apps/web` - React + TypeScript + Vite frontend (Phase 2 onward)
- `supabase/migrations` - SQL migrations (`0001` and `0002` written, not yet executed)
- `supabase/functions` - Edge Functions for sensitive operations (payments, webhooks, admin)
- `packages/shared` - shared Zod schemas and types
- `docs` - ARCHITECTURE.md, RBAC.md, ROUTES.md

## Local database (once Phase 1 is approved)
1. Install Docker and the Supabase CLI.
2. `supabase init` is already represented by this folder; run `supabase start` from the repo root.
3. `supabase db reset` applies all migrations to the LOCAL database only.
4. Copy `.env.example` to `apps/web/.env` and `supabase/functions/.env`, filling local values.

Never point local work at production keys. Use Paystack TEST keys until launch.
