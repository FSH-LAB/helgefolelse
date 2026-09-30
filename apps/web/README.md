# Web app

The Next.js app for Helgefolelse lives here. See the [project README](../../README.md) for setup and workspace commands.

Source code is in `src/app/` and `src/lib/`. Run `pnpm --filter web dev` from the repository root to work on this app alone.

## Docker

With Docker running, build from the repository root so Turborepo can include workspace dependencies:

```sh
docker build -f apps/web/Dockerfile -t helgefolelse-web:local .
docker run --rm -p 127.0.0.1:8080:8080 helgefolelse-web:local
```

Open [http://localhost:8080](http://localhost:8080) or check [http://localhost:8080/api/health](http://localhost:8080/api/health). Stop the container with Ctrl+C.