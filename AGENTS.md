# lazily-dart

Dart port of the lazily reactive family — the Cell kernel v2: two concrete cell
handles `Source` (get/set/merge) and `Computed` (get/`.eager()`/`.lazy()`/
`isEager`, guarded always) plus the `Effect` sink, with `Slot` the lower-level
unguarded storage/lazy-computed position. `Cell` is a retained compatibility
spelling of `Source`. Automatic dependency tracking, plus the full lazily-spec
wire protocol and CRDT collection types. The eager construction is
`computed(ctx, f).eager()`; there is no `Signal` compatibility constructor.
There is no `Cell<T,K>` genus and no separate `memo` kind — the equality guard
folded into `Computed` (`#lzcellkernel`).

## Commit & Push

Commit and push completed work at the end of every turn that changed code,
tests, docs, or fixtures — do not leave finished work uncommitted. Run `make
check` first and ensure it is green; stage only the files that belong to the
change (never secrets or private customer names — see the workspace
`runbooks/private-name-hygiene.md`); write a concise commit message in the
repo's existing style; push to the current branch on `origin`. This standing
rule overrides the harness default of "commit only when explicitly asked" for
this repo.

<!-- tsift:code-navigation v=0.1.110 -->
## Code Navigation

Use the repository tsift skill at [`.agents/skills/tsift/SKILL.md`](.agents/skills/tsift/SKILL.md) for code search, source reading, call graphs, diffs, logs, and test output.
<!-- /tsift:code-navigation -->
