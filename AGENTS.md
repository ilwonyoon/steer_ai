# Repository Guidelines

## Project Structure & Module Organization

This repository currently holds planning and design material for Steer, a macOS-first AI operations room for CLI coding agents. Keep root-level product documents concise and discoverable:

- `DESIGN.md`: Steer visual and interaction design direction.
- `AGENTS.md`: contributor and agent workflow guide.
- Future app code should live under clear top-level folders, for example `apps/mac/`, `packages/agent/`, `packages/cli/`, and `docs/`.

When adding source code, keep macOS UI, background agent logic, and CLI wrapper code separated. Do not mix prototype scripts into product source directories.

## Build, Test, and Development Commands

No build system is committed yet. Do not invent commands in docs or CI until the toolchain exists.

When implementation begins, document commands in `README.md` and keep this file aligned. Expected examples:

- `swift test`: run Swift package tests if the Mac app is split into packages.
- `npm test`: run TypeScript CLI/agent tests if Node tooling is used.
- `npm run lint`: run TypeScript formatting and lint checks.

## Coding Style & Naming Conventions

Use clear, platform-native naming. Swift types should use `PascalCase`; Swift methods and properties should use `camelCase`. TypeScript files should use `kebab-case.ts` unless a framework requires otherwise.

Prefer small modules with explicit ownership: UI, session registry, wrapper/pty control, message classification, and instruction delivery should remain separate. Keep comments short and useful.

## Testing Guidelines

Add tests with the feature they cover. For Swift, prefer XCTest naming like `testInjectsInstructionWhenSessionIsWaiting`. For TypeScript, use `*.test.ts` beside the source or under `tests/`.

Prioritize coverage for pty injection, session state transitions, SQLite persistence, classifier JSON parsing, and instruction delivery failures.

## Commit & Pull Request Guidelines

Git history was not readable in the current environment, so no existing convention could be inferred. Use concise imperative commits, for example `Add session instruction model` or `Document Mac agent architecture`.

Pull requests should include a short summary, test notes, screenshots for UI changes, and links to related issues or design docs. Call out security, privacy, or macOS permission changes explicitly.

## Security & Configuration Tips

Never commit transcripts, API keys, local database files, provisioning profiles, or personal shell configuration. Treat CLI output as sensitive because it may contain paths, secrets, or customer data.
