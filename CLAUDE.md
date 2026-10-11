# CLAUDE.md

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

## 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- If the user's proposed solution has a flaw or is the wrong approach, say so immediately — before writing any code. Don't implement a bad idea silently.

## 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

## 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

## 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

## 5. Test Verification

**If you modify code that has existing tests, run them after your changes.**

- After editing any file, check if there are test files linked to it.
- If tests exist, run them before considering the task done.
- If tests fail, fix the issue before responding — don't just report the failure.
- Do not mark a task complete if related tests are broken.

## 6. Roblox Guidelines

### Server / Client / Shared boundaries
- `server` scripts run only on the server (Script). Never put server logic in a LocalScript.
- `client` scripts run only on the client (LocalScript). Never access server-only services from here.
- `shared` modules can be required by both — keep them side-effect free.
- If unsure which boundary a piece of logic belongs to, ask before implementing.

### Luau conventions
- Use `.luau` extension and write idiomatic Luau, not generic Lua.
- Use strict typing (`--!strict`) where possible.
- Never use deprecated `wait()` — always use `task.wait()`.
- Prefer `task.spawn()` and `task.defer()` over raw coroutines.

### Roblox API
- RemoteEvents and RemoteFunctions must live in `ReplicatedStorage`.
- Use `game:GetService()` to access services — never index `game` directly (e.g. no `game.Workspace`).
- Avoid `Instance.new()` with a parent argument — set properties first, then set Parent last for performance.

### Executing code in Roblox Studio
When building or testing, execute code directly in Studio via the official Roblox MCP server configured in `.mcp.json` (server name: `Roblox_Studio`). Use its tools to run Lua, read Studio state, and check errors — do not simulate or guess Studio behavior locally. Studio must be open and the plugin connected before calling any MCP tool.
