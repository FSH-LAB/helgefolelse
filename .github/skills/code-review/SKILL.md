---
name: code-review
description: "Review pull requests in this repository with GitHub Copilot code review. Use for PR reviews to find actionable bugs, security issues, and regressions in the Next.js web app, Oslo-time weekend calculations, and GitHub Actions deployment workflows."
---

# Code review

Review the pull request diff against the base branch. Read nearby callers and tests when needed to establish whether a change actually breaks behavior. Follow the repository's `AGENTS.md` guidance and report only issues introduced by the pull request, not pre-existing problems or speculative style preferences.

1. Check changed behavior and its callers for incorrect outputs, missing edge cases, security risks, and test coverage that would catch a real regression. For `apps/web/src/lib/helgefolelse.ts`, pay particular attention to Europe/Oslo time, week boundaries (Friday 16:00 and Sunday 00:00), and daylight saving transitions. For changes to the time-driven UI, check hydration and timer cleanup. For `.github/workflows/` and the Dockerfile, check event and permission boundaries, untrusted inputs, image provenance, and whether deployment uses the intended commit and digest.
2. Use existing tests and checks when practical: `pnpm --filter web test`, `pnpm --filter web lint`, and `pnpm --filter web typecheck`. Do not treat a passing check as proof that changed behavior is correct; do not claim to have run a check unless it ran.
3. Leave concise, actionable review comments on the relevant changed lines. For each issue, explain the failure scenario and impact, and suggest a correction when clear. Prioritize by severity; avoid duplicate comments and do not request changes for preferences alone. If no actionable issue is found, do not invent one.

Keep the review focused on the diff. Do not edit code as part of the review.
