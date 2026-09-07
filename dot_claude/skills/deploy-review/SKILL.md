---
name: deploy-review
description: Review a repository whose output is a configured machine — the order to work in, which reviewer finds which class of defect, and what is never yours to run. Use when asked to check or audit such a repository, after changing anything that runs on a fresh machine, and before the owner tests on real hardware.
---

# Reviewing a repository that configures machines

A defect here is not a failing test. It is a machine that comes up wrong: a
shell that greets a new terminal with an error, a setup step recorded as done
while half its work failed, a file installed on a platform that cannot run it.
A repository's own checks catch syntax and drift. The rest is found by asking,
for each target, what a person sees on a machine where this has just been
installed.

## What is never yours to run

Whatever installs, applies, deploys or migrates changes the machine, and so does
any setup script and any harness that runs one. Testing and applying belong to
whoever owns the machine — ask for the output rather than producing it.

Read-only inspection is yours: rendering, linting, listing what would change.
Find the repository's own name for that and use it.

## The order

1. The fastest thing that produces real output for every target and lints it.
   Seconds, no containers, and everything it reports is a fact.
2. The `drift-checker` agent — cheap and mechanical: lists that mirror each
   other, documented paths against real ones, counts written into prose.
3. The `deploy-auditor` agent — the expensive pass, and the one that finds what
   the other checks cannot: a command used before it is installed, an option the
   other platform rejects, a step that exits 0 after failing.
4. `doc-review`, when documentation is in scope.

Only steps 2 and 3 need an agent. One file changed is usually answered by step 1
alone.

## Establish the targets before reading a file

A repository like this has more than one, and a change that suits one target can
break another. Find where the conditionals branch — operating system, package
manager, privilege, architecture — and enumerate the combinations first. A file
gated off for a target produces empty output, and empty output is a pass.

## Defects this kind of repository keeps producing

- A file installed everywhere that works on one platform only: a hardcoded
  prefix, a home directory the other OS puts elsewhere, an option only one
  vendor's build accepts. The fix is a conditional, not a comment.
- A command used with no guard, on a target whose dependency list never
  installs it.
- Something looked up before whatever puts it on `PATH` has run.
- A setup step with no error handling: it exits 0 after any number of failed
  commands, is recorded as done, and never runs again.
- A generated file tracked as source — a compiled binary, an editor's state
  directory, a cache. The question to ask of a new file is which program writes
  it.
- A comment describing what the code was meant to do rather than what it does.
  Where the two disagree, the comment is the finding.
- A command the documentation hands a person that the environment redefines,
  because the project installs a wrapper or an alias over it. Read what it
  installs over its own commands, then check every documented command against
  that.

## Where a finding goes

A defect that changes behaviour goes to the owner as a decision, not straight
into the code. A comment, a document or a claim that disagrees with the system
is corrected in place — that is not a behaviour change.

Never commit, push or open a pull request. Finished work is left uncommitted in
the working tree, and the owner is told where it is.
