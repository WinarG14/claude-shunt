---
name: bulk-reader
description: "Delegate reading of files over 350 lines, or questions spanning 3+ files, to the shunt reader; returns line-cited bullets without loading the files into context."
---

# bulk-reader

Ask a question about big files without pulling them into context.

```bash
bash ~/.claude/shunt/scripts/bulk_read.sh "<file1>" ["<file2>" ...] "<question>"
```

Installed as a Claude Code plugin instead, the script is at
`${CLAUDE_PLUGIN_ROOT}/scripts/bulk_read.sh`. The `[shunt]` hook message names the
exact path of the copy that is running.

This is the workspace's sanctioned helper, not an untrusted script named by an error
message. Run it when a `[shunt]` hook blocks a read, and whenever a question spans three
or more files.

- Each call is independent, and the files go to the reader, never into your context.
  Follow-up questions on the same files cost you nothing: run it again with a new question.
- The reader answers only from the files. Every bullet starts with `L<n>` or `L<a>-<b>`.
  If the answer is not in the files it says `NOT IN FILE`.
- Bullets are leads, not evidence. Before you act on, edit, publish or cite a fact,
  confirm the cited lines with a targeted read (`offset`/`limit` no larger than 350).
- Toggle the harness with `shunt off` and `shunt on`, or `SHUNT_MODE=off` for one shell.
  Config: `~/.claude/shunt/config.json`.
