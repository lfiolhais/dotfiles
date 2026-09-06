---
name: doc-review
description: Run a multi-level peer review of a documentation set — README, runbooks, agent instructions, and the documentation embedded in code — using reviewers who each hold a different knowledge level, then adjudicate and apply the findings. Use when documentation is described as a mess, before trusting a runbook, or after a large rewrite.
---

# Reviewing documentation at several knowledge levels

Nobody can review their own documentation. The gaps are invisible to whoever
wrote them, and they are different gaps for different readers: a newcomer finds
undefined terms, a specialist finds false claims, an operator finds unsafe
steps, and none of the three finds what the others do. A single reviewer, however
careful, returns one reader's list.

So the method is to run several reviewers who each hold a level, keep them from
contaminating each other, and adjudicate what comes back.

## Before dispatching anything

Read the whole documentation set yourself, and inventory it. Include the
documentation embedded in code — docstrings, comments, argument-parser help, and
the text scripts print — which is usually the larger half and the less reviewed.

Read the project's writing rules if it has any, since they are the standard
several reviewers will measure against.

Then establish ground truth on the things you will have to adjudicate later:
what the commands actually are, what the counts actually are, what the file
layout actually is. Reviewers will disagree with each other and with the
documents, and an orchestrator with no independent footing believes whoever
reported last.

## The reviewers

| Agent | Holds this level | Finds | Typical cost |
|---|---|---|---|
| `docs-newcomer` | knows the general craft, nothing about this domain | undefined terms, missing entry point, unexecutable steps | ~60k |
| `docs-structure` | sees the shape, not the sentences | duplication, wrong audience, reading order, rule violations | ~90k |
| `docs-procedure-walker` | an operator at 2am with something broken | unsafe steps, loops, data-loss traps | ~100k |
| `docs-in-code` | reads the code beneath each comment | stale comments, missing reasons, unusable help text | ~120k each |
| `docs-factchecker` | knows the system, trusts no document | claims that disagree with reality | ~200k |

Give each one the file list and the persona constraint, not a summary of what
you think is wrong. A reviewer told what to expect confirms it.

The newcomer's constraint matters most and is the easiest to lose: documents
only, no source, no running anything. A newcomer allowed to consult the code
resolves the undefined terms privately and reports none of them, which returns a
clean review of a document nobody else can read.

## Budget the review before dispatching it

A full pass over a mid-sized repository — five reviewers, with the in-code one
split by language, plus a verification pass over the rewrite — costs on the order
of 700k subagent tokens. That is the whole cost of the review, and it is why a
documentation pass exhausts a session that a feature would not.

Dispatch in tiers and stop when the findings stop changing what you would write.

**Tier one, always.** `docs-newcomer` and `docs-structure`, in parallel. Together
they cost around 150k and find the structural damage — the missing front door,
the duplication, the material filed where its reader will not look. Most of the
rewrite is determined by these two, and neither needs the source tree.

**Tier two, when procedures or code comments are in scope.**
`docs-procedure-walker` for anything an operator follows while something is
broken; `docs-in-code` when the complaint covers docstrings, comments and help
text as well as prose. Split `docs-in-code` by language or subtree — one
invocation per group, run in parallel — since its cost scales with how much
source it is handed.

**Tier three, after the rewrite.** `docs-factchecker`, pointed at the *new*
documents with a concrete list of claims to check. It is the most expensive
reviewer and the most valuable when aimed: a fact-check of the original is
largely wasted, because the passages it corrects are about to be rewritten.

Skip a tier when its findings would not change the work. A doc set with no
procedures does not need the procedure walker.

Two things that waste the budget quietly. Running the same reviewer twice on
overlapping file sets, because each invocation re-reads the repository from cold
— split by file, never by question. And letting a reviewer investigate rather
than report: the cost lives in tool calls, so an agent that reads twenty files to
be thorough about a finding it already has costs several times one that reports
it and moves on. The agent definitions carry explicit budgets for this reason;
if you write your own, give it one.

## Sharing context between reviewers

Reading a file twice looks like the obvious waste, and mostly it is not. An
agent's context is re-sent on every turn it takes, so content costs the same
whether it arrived through a `Read` or was pasted into the prompt. Handing a
reviewer the text of eleven files up front does not save the reads; it pays for
all eleven on every turn, including the eight it would never have opened.

What actually saves is not re-deriving, and not re-starting.

**Resume a reviewer instead of spawning a new one.** A completed agent keeps its
transcript, and sending it a message resumes it with everything it read still in
context. The re-review after a rewrite is the case that matters: a fresh
fact-checker re-reads the whole repository from cold, where the reviewer that
already mapped it can be asked "these files changed, recheck your findings" for
a fraction of that. Keep the agent names; they stay valid after completion.

**Write the ground truth once, and hand it to the reviewers that need it.**
Before dispatching, the orchestrator has already inventoried the corpus and
established the facts everyone will otherwise re-derive: the file list with line
counts, the real command surfaces, the actual counts, the module graph. Put that
in one scratch file and point the tier-two and tier-three agents at it. It is
smaller than the sources it summarises, which is the only reason it saves
anything.

**Share derived artifacts, never raw corpora.** A digest is worth passing because
it is smaller than its input. A file is not.

### Where sharing is harmful

Independence is the product here. Three of the five reviewers are worth less the
moment they are told what someone else found:

- `docs-newcomer` must read the raw documents and nothing else. Give it a
  ground-truth brief and it stops being a newcomer — the undefined terms resolve
  privately and go unreported, which is precisely the failure the persona exists
  to prevent.
- `docs-factchecker` must verify against the system, never against another
  agent's notes. A fact-checker reading a summary is checking the summary.
- `docs-procedure-walker` reads a procedure the way an operator meets it, with
  no briefing. Prior context is exactly what the operator does not have.

So do not wire the reviewers to talk to each other, and do not pass one's
findings into another's prompt in the same round. Route everything through the
orchestrator, which is also the only place the findings get adjudicated.

Forking the orchestrator is available and usually the wrong tool: a fork inherits
the entire parent conversation, including every report already returned, and runs
on the parent's model rather than the cheaper one these agents are pinned to.

## Adjudicating

Reviewers are confident and sometimes wrong. Check anything that will change
what you write, especially:

- a claim that a count is wrong — recount it;
- a claim that a command behaves a certain way — read the parser;
- a claim that a step is unsafe — read the script.

Two failure modes to watch for. A reviewer may overstate: "the Dock is replaced"
where the script appends. And a reviewer may report a *code* bug as a
documentation bug, because reading comments against their code is exactly how
code bugs surface.

Sort findings into three piles and treat them differently:

- **Documentation defects** — fix them.
- **Code bugs found on the way** — report them, do not fix them. A behaviour
  change is the owner's decision and a documentation pass is the wrong place for
  it. If a comment describes behaviour the code does not have, correct the
  comment to describe what the code does and flag the underlying bug.
- **Stale derived facts** — do not correct the number. Replace it with the
  command that prints it, or the count returns.

## Applying

Restructure before rewriting sentences. Most of what reads as bad prose is
material in the wrong file, and fixing the paragraph leaves the defect.

The usual shape of the fix:

- The human document gets a front door — what this is, prerequisites as
  commands, the first command in full, and what it changes irreversibly.
- Procedures a person needs move out of agent material into the human document.
- Agent material shrinks to what an agent needs *in addition*, and cites the
  human document rather than restating it. Duplication is removed, not
  synchronised.
- Derived numbers become commands.
- Every warning gains its invocation; every procedure gains a quoted success
  signal.

Verify as you go, with whatever the project provides: render the templates, lint
the scripts, run the linter over the code, check that anchors resolve and that
the mechanical sweeps come back clean.

Then review the rewrite. A pass that corrects twenty claims introduces new ones,
and you cannot see those either — dispatch `docs-factchecker` at the result and
expect it to find several. Fixing those is part of the job, not a sign the pass
failed.

## Reporting back

Say what changed, what you deliberately did not change, and what you found that
is a code bug rather than a documentation one. Where a reviewer's finding was
wrong, say so plainly rather than passing it through.
