# Git Hooks

`check.py` blocks the push if it fails only when the push updates
`refs/heads/main`. Pushes to any other branch are never blocked.

```sh
git config core.hooksPath tests/githooks
```
