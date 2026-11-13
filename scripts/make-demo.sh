#!/bin/bash
# Creates a folder of made-up projects that shows every case Rulebook handles.
# Used for the README screenshots:
#
#   ./scripts/make-demo.sh /tmp/rulebook-demo
#   build/Rulebook.app/Contents/MacOS/Rulebook --root /tmp/rulebook-demo --no-global --store /tmp/rulebook-demo-store
#
# With a second folder, it also fills that one as a stand-in home with global skills. Run the app with HOME and
# CFFIXED_USER_HOME set to it, and without --no-global:
#
#   ./scripts/make-demo.sh /tmp/demo-home/Projects /tmp/demo-home
set -euo pipefail

DEMO="${1:?usage: make-demo.sh <folder> [home]}"
DEMO_HOME="${2:-}"
if [ -e "$DEMO" ] && [ -n "$(ls -A "$DEMO")" ]; then
  echo "$DEMO already exists and isn't empty" >&2
  exit 1
fi
mkdir -p "$DEMO"
if [ -n "$DEMO_HOME" ]; then mkdir -p "$DEMO_HOME" && DEMO_HOME="$(cd "$DEMO_HOME" && pwd)"; fi
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

# Skills, in every relation their folders can have.
# skill <folder> <name> <description>, with the body on stdin.
skill() {
  mkdir -p "$1"
  { printf -- '---\nname: %s\ndescription: %s\n---\n\n' "$2" "$3"; cat; } > "$1/SKILL.md"
}

# Linked: one folder in .agents/skills, and a link to it where Claude Code looks.
skill aurora/.agents/skills/release-notes release-notes "Write the release notes for an Aurora release from the merged pull requests. Use when cutting a release or when asked what changed since the last one." <<'EOF'
# Release notes

1. List the pull requests merged since the last tag: `git log --merges --oneline $(git describe --tags --abbrev=0)..`
2. Group them under New, Improved and Fixed. Leave out refactors and dependency bumps.
3. Write each line for a customer, not for an engineer. See [the style guide](references/style.md).
4. Save the result to `CHANGELOG.md` above the previous release.
EOF
mkdir -p aurora/.agents/skills/release-notes/references aurora/.claude/skills
printf '# Style\n\n- One sentence per change, in the present tense.\n- Name the screen, not the component.\n' > aurora/.agents/skills/release-notes/references/style.md
ln -s ../../.agents/skills/release-notes aurora/.claude/skills/release-notes

# Diverged: the copy Claude Code loads was edited, and the one other agents load was not.
skill harbor-api/.agents/skills/db-migration db-migration "Write and check a Postgres migration for Harbor API. Use when a change touches the schema." <<'EOF'
# Database migration

1. Create the migration with `make migration name=<what_it_does>`.
2. Write both `up` and `down`. A migration without a working `down` doesn't merge.
3. Run `make migrate && make rollback && make migrate` against a local database.
EOF
skill harbor-api/.claude/skills/db-migration db-migration "Write and check a Postgres migration for Harbor API. Use when a change touches the schema." <<'EOF'
# Database migration

1. Create the migration with `make migration name=<what_it_does>`.
2. Write both `up` and `down`. A migration without a working `down` doesn't merge.
3. Add an index for every new foreign key, created with `CONCURRENTLY`.
4. Run `make migrate && make rollback && make migrate` against a local database.
EOF

# Duplicated: a tool wrote the same folder into both places.
for home in .agents .claude; do
skill ledger/$home/skills/month-close month-close "Reconcile a month of ledger entries against the bank export and report what doesn't match. Use for month-end close." <<'EOF'
# Month close

1. Import the bank export with `bin/ledger import <file.csv>`.
2. Run `bin/ledger reconcile --month <YYYY-MM>` and list every unmatched entry.
3. Never post an adjusting entry yourself. Report the differences and stop.
EOF
done

# Only where Claude Code looks, and it links to a file that isn't there.
skill fieldnotes/.claude/skills/field-report field-report "Turn raw field notes into a dated report with observations, photos and open questions. Use when notes are pasted in or a report is asked for." <<'EOF'
# Field report

Follow [the report template](assets/template.md). Keep the observer's own words in quotes.
EOF

# Only where other agents look.
skill sparrow/.agents/skills/sync-fixtures sync-fixtures "Refresh the recorded HTTP fixtures used by Sparrow's tests. Use when a test fails on a stale fixture." <<'EOF'
# Sync fixtures

Run `swift run sparrow-fixtures record`, then review the diff before committing it.
EOF

# No description, so agents can't tell when to use it. And a link whose target was deleted.
mkdir -p kiln/.claude/skills/glaze-check
printf '# Glaze check\n\nCompare the firing schedule in `schedules/` with the glaze notes before a kiln run.\n' > kiln/.claude/skills/glaze-check/SKILL.md
ln -s ../../.agents/skills/kiln-log kiln/.claude/skills/kiln-log

# The same skill copied into several projects, one copy changed since.
for name in beacon ember heron meadow; do
skill $name/.agents/skills/pr-description pr-description "Write a pull request description from the branch's commits and diff. Use when opening or updating a pull request." <<'EOF'
# Pull request description

Say what changed and why in two or three sentences, then how it was tested. Link the issue it closes.
EOF
mkdir -p $name/.claude/skills && ln -s ../../.agents/skills/pr-description $name/.claude/skills/pr-description
done
printf '\nAdd a screenshot for any change a user can see.\n' >> meadow/.agents/skills/pr-description/SKILL.md
# `npx skills` installed it, and says so in each project's lock file.
for name in beacon ember heron meadow; do
  printf '{\n  "version": 1,\n  "skills": {\n    "pr-description": {\n      "source": "northwind/agent-skills",\n      "sourceType": "github"\n    }\n  }\n}\n' > $name/skills-lock.json
done

# Global skills, when a stand-in home was given.
if [ -n "$DEMO_HOME" ]; then
  mkdir -p "$DEMO_HOME/.claude/skills" "$DEMO_HOME/.codex/skills"
  skill "$DEMO_HOME/.agents/skills/commit-message" commit-message "Write a commit message in the imperative mood from the staged diff. Use when asked to commit." <<'EOF'
# Commit message

A subject of at most 60 characters, a blank line, then why the change was made.
EOF
  ln -s ../../.agents/skills/commit-message "$DEMO_HOME/.claude/skills/commit-message"
  skill "$DEMO_HOME/.agents/skills/screenshot-tidy" screenshot-tidy "Rename, crop and compress screenshots before they go into a document or a pull request. Use when given screenshots to clean up." <<'EOF'
# Screenshot tidy

Crop to the window, strip metadata and convert to WebP with `cwebp -lossless`.
EOF
  # A personal skill with the name of a project's skill: Claude Code runs this one in Aurora too.
  skill "$DEMO_HOME/.claude/skills/release-notes" release-notes "Write release notes from the merged pull requests. Use when cutting a release." <<'EOF'
# Release notes

Group merged pull requests under Added, Changed and Fixed, newest first.
EOF
  skill "$DEMO_HOME/.codex/skills/sql-explain" sql-explain "Explain a slow SQL query from its plan and suggest an index. Use when given EXPLAIN output." <<'EOF'
# SQL explain

Read the plan from the innermost node out. Name the node that takes the most time before suggesting anything.
EOF
  ln -s ../../.agents/skills/tone-check "$DEMO_HOME/.codex/skills/tone-check"
  printf '{\n  "version": 3,\n  "skills": {\n    "commit-message": {\n      "source": "northwind/agent-skills",\n      "sourceType": "github"\n    }\n  }\n}\n' > "$DEMO_HOME/.agents/.skill-lock.json"
fi

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
