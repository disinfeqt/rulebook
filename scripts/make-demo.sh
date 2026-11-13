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
EOF

# AGENTS.md only: Claude Code reads it natively when there's no CLAUDE.md.
project sparrow
cat > sparrow/AGENTS.md <<'EOF'
# Sparrow

Tiny HTTP load tester written in Zig.

- `zig build test` runs the tests.
- No allocations in the request loop; use the arena in `src/run.zig`.
EOF

# Skipped by Claude: a CLAUDE.local.md hides AGENTS.md.
project kiln
cat > kiln/AGENTS.md <<'EOF'
# Kiln

Static site generator. Python 3.13, uv.

- `uv run pytest` runs the tests.
- Templates are Jinja2 in `kiln/templates/`.
EOF
cat > kiln/CLAUDE.local.md <<'EOF'
Use my local Postgres on port 5433.
EOF

# Repos with no instructions at all.
project atlas
project pebble

echo "Demo projects created in $DEMO"
