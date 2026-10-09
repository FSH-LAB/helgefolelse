# Helgefolelse

A small website that shows how close it feels to the weekend. The reading rises from Monday to Friday at 16:00, stays at 100 through Saturday, and falls on Sunday. All times are interpreted in `Europe/Oslo`.

## Getting started

Install Node.js 24 or newer and enable pnpm through Corepack. The repository pins the pnpm version in `package.json`.

```sh
corepack enable pnpm
pnpm install
pnpm dev
```

Open [http://localhost:3000](http://localhost:3000). Run commands from the repository root unless noted otherwise.

## Commands

| Command                 | Purpose                           |
| ----------------------- | --------------------------------- |
| `pnpm dev`              | Start the development server      |
| `pnpm build`            | Build the web app for production  |
| `pnpm lint`             | Run ESLint                        |
| `pnpm lint:workflows`   | Check GitHub Actions workflows    |
| `pnpm typecheck`        | Run TypeScript checks             |
| `pnpm test`             | Run app unit tests                |
| `pnpm format:check`     | Check formatting for CI           |
| `pnpm format`           | Format supported files            |
| `pnpm --filter web dev` | Run only the web app's dev script |

The workflows lint command requires actionlint locally (`brew install actionlint`). CI installs a pinned version.

Run the app's smoke test against a local server with:

```sh
SMOKE_URL=http://localhost:8080 SHA="$(git rev-parse HEAD)" pnpm --filter web test:smoke
```

Start the server or container with the same `GIT_SHA` value. Unit tests do not need a running server.

## Delivery

Pull requests run app and infrastructure checks without deploying. A push to `main` builds, scans, and attests one GHCR image, then deploys that same digest through `dev`, `staging`, and `production`. Staging and production require environment approval. Each deployment applies its Terraform configuration, smoke-tests a no-traffic Cloud Run revision, and promotes it only after the test passes.

Run **Deploy** manually on `main` with an older commit SHA or release tag to redeploy or roll back. Infrastructure ownership and operator commands are in [infra/README.md](infra/README.md).

Use pnpm for workspace dependencies: `pnpm --filter web add <package>`, then commit `pnpm-lock.yaml`.
