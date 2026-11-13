#!/bin/bash
# Creates a folder of made-up projects that shows every case Rulebook handles.
# Used for the README screenshots:
#
#   ./scripts/make-demo.sh /tmp/rulebook-demo
#   build/Rulebook.app/Contents/MacOS/Rulebook --root /tmp/rulebook-demo --no-global --store /tmp/rulebook-demo-store
set -euo pipefail

DEMO="${1:?usage: make-demo.sh <folder>}"
if [ -e "$DEMO" ] && [ -n "$(ls -A "$DEMO")" ]; then
  echo "$DEMO already exists and isn't empty" >&2
  exit 1
fi
mkdir -p "$DEMO"
cd "$DEMO"

project() { mkdir -p "$1" && git -C "$1" init -q; }

CONVEX_BLOCK='<!-- convex-ai-start -->
This project uses [Convex](https://convex.dev) as its backend.

When working on Convex code, **always read `convex/_generated/ai/guidelines.md` first** for important guidelines on how to correctly use Convex APIs and patterns.
<!-- convex-ai-end -->'

# Linked: CLAUDE.md only imports AGENTS.md, so both agents read one file.
project aurora
mkdir -p aurora/lib aurora/app/api/checkout aurora/e2e
cat > aurora/package.json <<'EOF'
{
  "name": "aurora",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "test": "vitest run",
    "test:e2e": "playwright test",
    "lint": "next lint"
  }
}
EOF
cat > aurora/lib/money.ts <<'EOF'
export function formatPrice(cents: number, currency = "USD") {
  return new Intl.NumberFormat("en-US", { style: "currency", currency }).format(cents / 100);
}
EOF
echo 'export async function POST() {}' > aurora/app/api/checkout/route.ts
cat > aurora/AGENTS.md <<'EOF'
# Aurora

Storefront for the Aurora coffee subscription. Next.js 16, Stripe, Tailwind.

## Commands

- `pnpm dev` starts the app on port 3000
- `pnpm test` runs Vitest; `pnpm test:e2e` runs Playwright against a local build
- `pnpm lint` must pass before you commit

## Conventions

- You are an expert senior Next.js engineer. ALWAYS write clean, production-ready code.
- Server components by default. Add `"use client"` only to interactive leaves.
- Money is stored in integer cents. Format it with `formatPrice()` from `lib/money.ts`.
- Never call Stripe from the browser. Go through the route handlers in `app/api/checkout/`.
- Tailwind only, no CSS modules.
- Keep components small and focused.
- Use pnpm, never npm or yarn.
- Don't add comments that restate what the code does.
- Ask before adding a dependency.

<!-- BEGIN:nextjs-agent-rules -->
# Read the Next.js docs first
APIs and conventions may differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing code.
<!-- END:nextjs-agent-rules -->
EOF
echo '@AGENTS.md' > aurora/CLAUDE.md

# Diverged: two separate files that drifted apart.
project harbor-api
cat > harbor-api/CLAUDE.md <<'EOF'
# Harbor API

Booking API for marina berths. Go 1.23, Postgres 16, sqlc for queries.

## Commands

- `make dev` runs the API with live reload on :8080
- `make test` runs unit tests
- `make migrate` applies migrations in `db/migrations/`

## Rules

- IMPORTANT: Always run `make test` before saying you're done.
- Write queries in `db/queries/*.sql` and run `make sqlc`. Never hand-write SQL in Go files.
- Return errors with `fmt.Errorf("...: %w", err)`; don't panic.
- Handlers live in `internal/http/`, one file per resource.
- Use `slog` for logging, never `fmt.Println`.
- Ask @maria before changing the billing tables.
EOF
cat > harbor-api/AGENTS.md <<'EOF'
# Harbor API

Booking API for marina berths. Go 1.24, Postgres 16, sqlc for queries.

## Commands

- `make dev` runs the API with live reload on :8080
- `make test` runs unit tests; `make test-integration` needs Docker
- `make migrate` applies migrations in `db/migrations/`

## Code style

- Write queries in `db/queries/*.sql` and run `make sqlc`. Never hand-write SQL in Go files.
- Return errors with `fmt.Errorf("...: %w", err)`; don't panic.
- Handlers live in `internal/http/`, one file per resource.
- Use `slog` for logging.
- Prices are integer cents. Never use floats for money.

## Pull requests

- Keep PRs under 400 lines.
- Run `make lint test` before pushing.
EOF

# Duplicated: byte-identical copies.
project ledger
cat > ledger/AGENTS.md <<'EOF'
# Ledger

Plain-text accounting CLI in Rust.

- `cargo test` before every commit; `cargo clippy -- -D warnings` must be clean.
- Amounts are `rust_decimal::Decimal`, never `f64`.
- Parser lives in `src/parse/`. Add a fixture under `tests/fixtures/` for every new syntax.
- Keep the public API in `src/lib.rs` small; everything else is `pub(crate)`.
- Don't add comments that restate what the code does.
- Ask before adding a dependency.

<!-- BEGIN:nextjs-agent-rules -->
# Next.js: read the docs before coding
Before any Next.js work, read the relevant doc in `node_modules/next/dist/docs/`.
<!-- END:nextjs-agent-rules -->
EOF
cp ledger/AGENTS.md ledger/CLAUDE.md

# Layered: CLAUDE.md imports AGENTS.md and adds Claude-only rules, but repeats a tool block.
project tidepool
cat > tidepool/AGENTS.md <<EOF
# Tidepool

Shared reading list app. React Native (Expo) client, Convex backend.

- \`pnpm ios\` / \`pnpm android\` run the app; \`npx convex dev\` runs the backend.
- All data access goes through Convex queries and mutations in \`convex/\`.
- Styles use the tokens in \`theme/tokens.ts\`. No inline colors.
- Use pnpm, never npm or yarn.

$CONVEX_BLOCK
EOF
cat > tidepool/CLAUDE.md <<EOF
@AGENTS.md

## Claude Code

- Use the Expo MCP server to read device logs instead of asking me to copy them.
- Prefer small commits with conventional messages.

$CONVEX_BLOCK
EOF

# Claude only: Codex never sees these rules, and the title came from another file.
project fieldnotes
cat > fieldnotes/CLAUDE.md <<'EOF'
# AGENTS.md

Fieldnotes is a SwiftUI journaling app for iOS and macOS.

- Build with `xcodebuild -scheme Fieldnotes -destination 'platform=iOS Simulator,name=iPhone 17'`.
- SwiftData for storage; migrations live in `Fieldnotes/Model/Migrations/`.
- Every view gets a `#Preview`.
- Strings go through `String(localized:)`.
- Ask before adding a dependency.
EOF

# AGENTS.md only: Claude Code reads it natively when there's no CLAUDE.md.
project sparrow
cat > sparrow/AGENTS.md <<'EOF'
# Sparrow

Tiny HTTP load tester written in Zig.

- `zig build test` runs the tests.
- No allocations in the request loop; use the arena in `src/run.zig`.
- Don't add comments that restate what the code does.
EOF

# Skipped by Claude: a CLAUDE.local.md hides AGENTS.md.
project kiln
cat > kiln/AGENTS.md <<'EOF'
# Kiln

Static site generator. Python 3.13, uv.

- `uv run pytest` runs the tests.
- Templates are Jinja2 in `kiln/templates/`.
- Don't write comments that restate what the code does.
EOF
cat > kiln/CLAUDE.local.md <<'EOF'
Use my local Postgres on port 5433.
EOF

# Everyday projects in good order, so the overview reads like a real projects folder. Several repeat the
# same rules, one of them in other words, for Repeated Rules.
linked() { project "$1"; cat > "$1/AGENTS.md"; echo '@AGENTS.md' > "$1/CLAUDE.md"; }
agents_only() { project "$1"; cat > "$1/AGENTS.md"; }

linked beacon <<'EOF'
# Beacon

Status page for internal services. SvelteKit on Cloudflare Workers.

- `pnpm dev` runs it locally; `pnpm deploy` ships to Workers.
- Use pnpm, never npm or yarn.
- Incidents are defined in `src/lib/incidents.ts`.
EOF

agents_only cinder <<'EOF'
# Cinder

A small game engine for jams. Rust and wgpu.

- `cargo run --example sandbox` opens the test scene.
- Don't add comments that restate what the code does.
- Shaders live in `assets/shaders/` as WGSL.
EOF

linked driftwood <<'EOF'
# Driftwood

Photo backup daemon for a home NAS. Go 1.24.

- `go test ./...` before every commit.
- Ask before adding a dependency.
- Never delete a file on the NAS; move it to `.trash/` instead.
EOF

linked ember <<'EOF'
# Ember

Design tokens for every app, built with Style Dictionary.

- Use pnpm, never npm or yarn.
- Edit `tokens/*.json`. Everything in `dist/` is generated.
EOF

agents_only fjord <<'EOF'
# Fjord

Terraform for the staging and production AWS accounts.

- Run `terraform fmt` and `terraform validate` before committing.
- Never apply from a laptop. CI applies on merge to `main`.
EOF

linked heron <<'EOF'
# Heron

Newsletter editor. Remix, Prisma, Postgres.

- Use pnpm. Never use npm or yarn.
- Migrations go through `pnpm db:migrate`, never `prisma db push`.
EOF

linked juniper <<'EOF'
# Juniper

Recipe app for iPhone and iPad. SwiftUI and CloudKit.

- Every view gets a `#Preview`.
- Ask before adding a dependency.
EOF

project lantern
cat > lantern/CLAUDE.md <<'EOF'
# Lantern

Scripts for my notes archive. Python 3.13, uv.

- `uv run lantern sync` pulls the latest notes.
- Notes are plain Markdown; never rewrite their front matter.
EOF

linked meadow <<'EOF'
# Meadow

Marketing site. Astro and Tailwind.

- Use pnpm, never npm or yarn.
- Don't add comments that restate what the code does.
- Images go through `astro:assets`; no raw `<img>` tags.
EOF

linked nimbus <<'EOF'
# Nimbus

Weather API proxy with caching. Node 22 and Hono.

- Use pnpm, never npm or yarn.
- Ask before adding a dependency.
- Cache keys are built in `src/cache.ts`; don't build them inline.
EOF

agents_only orchard <<'EOF'
# Orchard

Pipeline for orchard sensor readings. Python and DuckDB.

- `uv run pytest` runs the tests.
- Don't add comments that restate what the code does.
EOF

linked quill <<'EOF'
# Quill

Markdown editor for the Mac. AppKit and TextKit 2.

- Don't add comments that restate what the code does.
- Keep typing latency under 16 ms; profile with Instruments before merging editor changes.
EOF

linked willow <<'EOF'
# Willow

Habit tracker. Expo and SQLite.

- Use pnpm, never npm or yarn.
- Schema changes need a migration in `db/migrations/`.
EOF

linked wren <<'EOF'
# Wren

CLI for rotating API keys. Go.

- `go test ./...` and `golangci-lint run` must pass.
- Never print a key, even in debug output.
EOF

# Repos with no instructions at all.
project atlas
project glacier
project pebble
project summit

# Files changed over the past weeks, not all in the last minute.
age() { touch -t "$(date -v-"$2" +%Y%m%d%H%M)" "$1"; }
age harbor-api/AGENTS.md 3H; age harbor-api/CLAUDE.md 2d; age kiln/AGENTS.md 5d; age ledger/AGENTS.md 1d; age kiln/CLAUDE.local.md 5d
age tidepool/CLAUDE.md 40M; age tidepool/AGENTS.md 4d; age aurora/AGENTS.md 1H; age fieldnotes/CLAUDE.md 9d
age sparrow/AGENTS.md 23d; age beacon/AGENTS.md 4d; age cinder/AGENTS.md 47d; age driftwood/AGENTS.md 12d
age ember/AGENTS.md 6H; age fjord/AGENTS.md 31d; age heron/AGENTS.md 2d; age juniper/AGENTS.md 8d
age lantern/CLAUDE.md 64d; age meadow/AGENTS.md 1d; age nimbus/AGENTS.md 15d; age orchard/AGENTS.md 19d
age quill/AGENTS.md 3d; age willow/AGENTS.md 26d; age wren/AGENTS.md 90d

echo "Demo projects created in $DEMO"
