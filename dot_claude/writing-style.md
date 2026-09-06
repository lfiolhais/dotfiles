# Documentation and writing rules

Applies to every document, code comment, commit message and generated file.

## Describe the current system, nothing else

This is the rule broken most often, and it covers two things that look
different and are the same mistake.

- No references to earlier revisions of the document: "an earlier survey said",
  "the previous version", "corrected here", "what used to be here", "(never
  previously captured)".
- No references to earlier states of the system: an old filename beside the
  current one, "was called X until <date>", "was removed on <date>", "installed
  in 2021 with <script>", "this host once dropped every query for four days".

A document describes what exists now. If a thing no longer exists, it does not
appear — not in a parenthesis, not as a footnote, not as background. If a past
failure taught something, the lesson is written as a present-tense property of
the system: not "this broke in September and here is what happened", but "a
database from the other host cannot be read here, and the symptom is X".

Dates belong in a document only when they are still operative — a certificate
expiry, a scheduled job, a release that a version constraint depends on.

A name that no longer resolves is the same defect in miniature: an alias the
shell does not define, a tool the machine never installs, a config directory
that was deleted, a settings pane the operating system removed. Each reads as
current, and the reader loses time proving it is not. Before naming a thing,
check that it is there.

### Never write down a number a command can print

Counts drift silently and nothing fails when they do. "29 of the 41 installed
casks", "17 silenced, 12 still self-updating", "120 `defaults write` calls",
"all four targets" — each is false after the next commit, and a reader has no
way to tell which are still true. Two documents that quote the same count drift
apart independently, which is worse: now they disagree and neither is marked.

Name the command that produces the number instead:

| Written | Meant |
|---|---|
| "Coverage today is 17 silenced, 12 still self-updating." | "`cask-updates status` prints the current tally." |
| "It renders all four `distro × sudo` combinations." | "It renders every distro in `IMAGES` crossed with sudo and no-sudo." |

A number is worth writing when it is a fixed property — a port, a protocol
constant, a timeout the code sets. A number describing a collection that can
grow belongs in the collection, not in prose about it.

## Say it directly

Cut the run-up. Sentences that announce a point instead of making it:

| Written | Meant |
|---|---|
| "The practical consequence is that upstream docs don't describe this machine." | "Upstream docs don't describe this machine." |
| "Two rules follow. Never copy..." | "Never copy..." |
| "It is worth knowing that..." | say the thing |
| "The differences that come up in practice:" | "The differences:" |

Delete: "it is worth noting", "the practical consequence is", "what this means
is", "it should be pointed out", "as mentioned", "in order to", "at this point
in time". If a sentence can lose its first clause and still say the same thing,
it should.

## Cut the preamble, never the reason

Concision applies to run-up, not to causation. Every instruction states why it
exists, because a reader meeting it in isolation has to be able to act on it.

"Never copy a gravity database between the two resolvers in either direction"
is unusable on its own: it reads as superstition, and the first person with a
plausible reason to do it will. "Blocklists are rebuilt locally with `pihole
-g` rather than copied from delta7, because a copy in either direction moves a
database in the wrong schema and produces the failure above" can be acted on
and can be argued with.

The test: if an instruction were encountered with no surrounding context, would
it be followed, or worked around? An instruction that has to be taken on trust
gets ignored the moment it is inconvenient.

## Write in the positive

State what is needed and why, rather than what breaks in its absence.

| Negative | Positive |
|---|---|
| "Without `2>&1` a check sees nothing and calls a valid config broken." | "The `2>&1` is needed because `dnsmasq-test` writes its result to stderr." |
| "`>quit` is required — the command hangs without it." | "`>quit` ends the session. FTL keeps the connection open for further commands." |
| "Restart Caddy rather than reloading, or the result is a 502." | "A newly attached container needs a Caddy restart to be reachable; a reload leaves the stale cache in place and returns a 502." |

Describing a failure is fine when the failure is the subject — a symptom table,
or a section about what goes wrong. It is the wrong frame for an instruction.

## Every paragraph earns its place

A section stops when it has delivered what it exists to deliver. A section
headed "Reaching the admin interface" needs the URL; it does not need an
account of how someone reading a different file might have reached a different
conclusion. Detail that does not change what the reader does next belongs
somewhere it does, or nowhere.

Before keeping a paragraph: does this change an action, or is it explaining a
route the reader is not taking?

## Audience separation

- Documentation written for people and material written for agents are separate
  trees. Human documentation gets full sentences, pasteable commands, and no
  shorthand that only makes sense to whoever wrote it.
- Agent material — skills, agent definitions, collected host surveys, evidence
  tables — belongs in its own directory and may be dense.
- `CLAUDE.md` and equivalent agent-instruction files are never cited to a
  human. Do not reference them from human documentation, from code comments, or
  from anywhere a person reads.
- A file a person edits must never redirect to agent material. State the fact
  inline. "See <agent-notes>/host.md" is useless to a human.
- A finding that serves both audiences is written twice, in the register each
  one calls for.

A procedure that exists only in agent material is undocumented. This is the
expensive direction of the rule and the easy one to miss: the agent file grows
because it is where the last change happened to be explained, and a person
following the human documentation never learns that creating a contact without
tracking it loses the contact at the next apply. Before a fact goes into agent
material, ask whether a person would need it. If so it belongs in the human
document, and the agent file cites it rather than restating it.

Restating it is the other half of the same defect. Two copies of one procedure
agree on the day they are written and drift from then on, with nothing to detect
it — whichever document a reader opens first wins. Duplication between documents
is a maintenance obligation that no test enforces, so it has to be removed
rather than managed.

## A document set has a front door

The reader arrives with a task, not with a map. Somewhere there has to be a file
that says what the thing is, what it is for, and what to run first — and it has
to be the file a stranger would open, which in a repository means `README.md`.

Missing this is not a small gap. A repository whose documentation covers
packages, applications, mail and network shares in detail, but never says how to
install any of it, is unusable by the one reader who needs it most: the person
setting up a replacement machine.

The front door owes the reader four things before anything else:

- what this is, in a sentence that does not assume the tool it is built on;
- what has to exist first, named as commands — including the tools a check or a
  build fails without, not only the optional ones;
- the first command, complete, with its real arguments;
- what that command changes, where it is not reversible.

Everything after that may assume the reader has read it. Nothing before it can.

## Register

- No second person. Not "you", "your", "yourself". Write impersonally or as an
  imperative: "Run X", "The role asserts...", "a host that can still resolve".
  Agent definition files are the exception, since those are prompts addressed
  to the agent.
- No bolding for emphasis. Bold is for structural list lead-ins only. Never
  bold a whole sentence, and never bold a word for effect.
- Technical documentation, not conversation.

## Structure and headings

- Explain the cause before the consequence. A section about something unusual
  opens by saying why it is that way, in ordinary sentences, and only then
  lists what follows from it. "This machine runs an older version because the
  hardware cannot take the current one, so upstream documentation does not
  describe it" is the shape; a table of differences with no preamble is not.
- Headings name their subject: "Pi-hole is version 5 here", "Reaching the admin
  interface", "When something is wrong". Never a heading that counts its own
  contents — "Three facts that produce confusing symptoms", "Five things to
  check" — because the count is an artefact of the writing rather than a
  property of the subject, and it goes stale as soon as an item is added. Never
  a heading that editorialises: "The single most useful diagnostic", "The
  failure worth recognising".
- Prose carries the explanation; tables and code carry the specifics. A table
  is right for symptom-to-cause, for a file inventory, for a version
  comparison. It is wrong as a substitute for a paragraph that has to reason
  about something.
- Say plainly what should not be trusted, and why: documentation describing a
  different version, a configuration file overridden elsewhere, a status
  command that stays green through the failure being described.
- Write the way a colleague would explain it out loud. A sentence that would
  sound like a generated summary if spoken gets rewritten.

## Content

- Avoid filler that sounds precise and is not: "source of truth", "gates",
  "nearby trap", "load-bearing". Say the concrete thing instead — "the only
  file to edit", "a pre-write syntax check", "without these options a missing
  disk stops the boot".
- Delete a completed item rather than marking it done or striking it through.
- Verbosity is a defect. Answer what was asked, not adjacent questions.

## Procedures

A procedure is written by walking it, not by describing it. Read each step as
though executing it with the system already broken and the next step unread.

- Arity has to match. If a step captures N things, the step that restores them
  must restore N things. A capture that saves every row followed by a restore
  that inserts one row is a data-loss bug that reads as correct: the operator
  finishes, sees no error, and has lost the rest.
- Say what is destroyed. Any step that recreates something from a template or a
  default starts it empty. Enumerate what survives and what does not, because
  the reader cannot see the difference until much later.
- Warnings must be consistent across procedures of comparable risk. If a
  two-minute maintenance step carries "check the other node first" and a
  ten-minute destructive rebuild does not, the reader correctly infers the
  rebuild is safer. Uneven warnings are worse than none.
- Give a success signal: what the command prints when it worked, roughly how
  long it takes, and what to do when it fails a second time. A procedure whose
  failure path points back at itself is a loop.
- Rule out the cheap causes first. A symptom table that sends every instance of
  a common failure to the most destructive remedy will get that remedy run for
  a full disk.
- Placeholders must be resolvable. `<uuid>`, `<url>`, `<name>` need a stated
  way to find the current value, not just a shape.
- Verify at the end against the thing that actually indicates health, naming
  the command and the expected output. "Confirm it worked" is not a step, and
  neither is a paraphrase of the output — quote the line the command prints, so
  the reader can match it against what is on screen.
- Say where a step stops and waits. A passphrase prompt, `sudo`, `chsh`, an
  installer that asks before proceeding: an unattended procedure that blocks on
  a question the reader was not warned about is indistinguishable from a hang.
- Prerequisites are part of the procedure. A harness that fails without `ruff`,
  `shellcheck`, or a newer interpreter has those as requirements, and listing
  only the optional ones tells the reader the opposite of the truth.
- A step that cannot be repeated needs its reset command. "Keep them idempotent"
  is advice to whoever writes the script; the reader who has just watched one
  fail halfway needs the command that makes it run again.

## Every warning implies a command

A document that says to do something contains the exact invocation. Two
patterns recur:

- A caution with no remedy: "restart rather than reload, or the cache goes
  stale", in a document that never gives the restart command.
- A remedy named but not spelled: "re-apply the setting under NetworkManager",
  "re-render with `--tags dns`" — a tool name or a flag fragment where a
  runnable command belongs.

The same applies to file formats. Any file the reader is told to edit gets one
real example of a correct entry, particularly where the only example shown is
of what not to write.

Output that looks like a failure and is not — a redirect, a non-zero exit
meaning "nothing to do" — gets a word saying so, or it will be chased.

## Documentation that passes through a renderer

Text inside a docstring, a template, a heredoc or a generator is not read where
it is written. Something processes it first, and the processing can change it.

- A command inside a docstring is rendered before anyone sees it. A line
  continuation written `\\` in a raw string arrives as two backslashes, and the
  command a reader pastes is broken in a way that is invisible in the source.
  Render it, paste the result back, and check it runs.
- A comment in a generator is documentation in every file that generator writes.
  A note about a table that was removed, sitting in a header constant, is
  reproduced into the generated data file on every write.
- Help text is the documentation most people read. A flag whose help reads "its
  el name" documents nothing: it has to say what the value is and when the flag
  is required. A destructive subcommand says what it destroys; a flag says what
  happens when it is omitted.
- Printed instructions are a procedure, held to the whole procedure standard:
  resolvable placeholders, a stated success signal, and no counting of what
  follows — a script that announces "three things" and then branches to two is
  wrong on one of its paths.

## Check claims against the system, not against memory

Every statement about configuration is verifiable, so verify it: group
membership, ports, file paths, version numbers, which host runs what. A
document that names the wrong member of a redundancy group is worse than one
that omits it, because it will be believed.

Verify by running the thing, not by reading it. A claim about what a tool
records, what a permission prefix expands to, or what order steps execute in is
answered in minutes by a throwaway instance and guessed wrong surprisingly
often. Where an experiment is impossible, say the claim is unverified rather
than stating it flatly.

Never reference a document that does not exist. A pointer to "the separate
runbook", with no filename, is a dead end at the moment it is needed most.

This applies to comments with more force than to prose, because a comment is
believed without being checked. Read the line a comment sits on before trusting
it: a caption reading "Set Home as the default location for new Finder windows"
above a value meaning Desktop will be copied, cited, and never questioned. Two
comments that each claim the same setting mean at least one is wrong.

The converse is also a defect. A line whose reason is not obvious — a sleep, a
retry, an odd flag, a defensive branch, a magic constant, a redirect that hides
output, a filter that differs from the one three functions above — needs a
sentence saying why, or the next person deletes it. The test is whether a
competent reader tidying the file would remove it and break something.

When a document has to explain why two machines doing the same job present
different interfaces — different ports, different paths for the same setting —
the inconsistency is usually the defect. Fix the system and delete the
explanation.

## Review with readers who are not the author

Different gaps are visible to different readers, and none are visible to
whoever wrote the text.

- A competent generalist who does not know the domain finds undefined terms and
  procedures that cannot be executed as written.
- A specialist in the domain finds claims that disagree with the system.
- A reviewer asked to walk a destructive procedure step by step, saying where
  they would hesitate, finds the steps that are unsafe rather than unclear.
- A reviewer given only the structure — which document holds what, what is
  duplicated, what each file's audience is — finds the material filed where its
  reader will not look.

Ask for quoted text and a specific consequence — "I could not tell whether X is
a service or a binary" — rather than a judgement of quality.

Hold each reviewer to their level. A reviewer told to be a newcomer and allowed
to consult the source stops being a newcomer, and the undefined terms become
invisible again. The newcomer reads the documents and nothing else; the
specialist reads the system and trusts none of the documents.

Review the rewrite too. A pass that fixes twenty claims introduces new ones, and
the author cannot see those either.

## Reference and runbook documents

Anything meant to be followed while something is broken:

- No open items, no checkboxes, no TODOs. Open work lives in the backlog
  document. An item that turns out to be already resolved is verified and
  deleted, not carried forward.
- No design rationale. "Why X and not Y" is history, not a recovery step. Keep
  a rationale only where it is diagnostic — a fact that changes what the reader
  checks next.
- List only what a rebuild must restore by hand. Inventorying things the
  automation already manages makes the rebuild do the work twice.
- Instructions must match what the automation actually renders. A runbook that
  says to hand-edit a file the config management overwrites produces a fix that
  silently disappears on the next run.
