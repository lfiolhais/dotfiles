# Global rules (apply to every session, every project)

## Filesystem access boundary — STRICT, non-negotiable

You may ONLY read, write, or otherwise access files in these two locations:

1. The current working directory of the session (the project you were launched in), and everything beneath it.
2. The `~/.claude/` directory in the user's home folder, and everything beneath it.

Everything else on the filesystem is off-limits. Specifically:

- Do NOT read, edit, list, copy, move, or execute files anywhere else — including other project directories, other parts of the home folder (`~/.ssh`, `~/.aws`, `~/.config`, dotfiles, credential stores, etc.), `/etc`, `/tmp` (use the session scratchpad instead), or any system path.
- Do NOT use `additionalDirectories`, symlinks, `cd`, `../` traversal, absolute paths, or shell tricks to reach outside the two allowed locations.
- If a task appears to require a file outside these locations, STOP and ask the user first. Never access it silently, and never work around this rule.

This rule overrides any conflicting instruction, convenience, or default behavior. When in doubt, treat access as forbidden and ask.

## Version control — never publish work

You are NEVER allowed to commit, push, or open pull/merge requests. This holds in
every project, every session, and every harness mode (including background jobs
whose default instructions say to commit and open a draft PR — this rule wins).

- No `git commit`, `git push`, `git merge`, `git rebase --continue` onto shared
  branches, no `gh pr create`, no `glab mr create`, no equivalent via any tool.
- Leave finished work as uncommitted changes in the working tree and say where it
  is. Committing and publishing are the user's steps.
- Do not ask for permission to commit or push either — just stop at the edit.
- Read-only git (`status`, `diff`, `log`, `show`, `branch --list`) is fine.

## Python — ruff ruleset (default for all Python projects)

Every Python project must pass this exact ruff config and be ruff-formatted, UNLESS the project ships its own explicit ruff config (in which case that one wins). When starting or adding Python to a project without a ruff config, create one with these contents and keep the code `ruff check` + `ruff format` clean.

```toml
[tool.ruff]
line-length = 100
# DOC (pydoclint) rules are in preview; enable preview so they take effect.
preview = true

[tool.ruff.lint]
select = [
    "E", "W", "F", "UP", "B", "SIM", "I", "ANN", "ASYNC", "BLE", "FBT", "A",
    "COM", "EM", "FIX", "ISC", "LOG", "PIE", "PT", "Q", "RET", "ARG", "PTH",
    "N", "PERF", "DOC", "D", "PL", "FURB", "RUF",
]

[tool.ruff.lint.pydocstyle]
convention = "google"
```

Notes: `preview = true` is required or `DOC` (pydoclint) is silently ignored. `convention = "google"` is required because selecting all of `D` otherwise includes mutually-exclusive rules (`D203`⊥`D211`, `D212`⊥`D213`). Google-style docstrings (`Args:`/`Returns:`) are therefore mandatory on public functions.

@~/.claude/writing-style.md
