# Comment context rule (ERROR 20)

**Binding for every agent and every gate that audits comments.**

## Failure mode

Parent ERROR 20: a defect was reported from  
`host/libmisterplex/ddr_bank_release_select.hpp` by quoting a fragment that  
mentioned `bank_vsync_count` / `frames_done` **without the enclosing block**.  
The block is a **`HISTORICAL FAULT (fixed…)`** note that states the **opposite**  
of "current code is wrong": product RTL packs the real swap counter; do not  
reintroduce vsync-as-frames_done.

A green or red gate built on a decontextualized line is **false evidence**.

## Required procedure

1. **Never flag a comment from a single line or `file:line` alone.**
2. Load the **entire contiguous comment block** (from the start of the `//` or  
   `/*` run through the blank line or code that ends it).
3. If the block contains any of these markers (case-insensitive), treat the  
   body as **documentation of past fault + current correct behaviour**, not as  
   a present-tense product claim:
   - `HISTORICAL`
   - `HISTORICAL FAULT`
   - `FIXED`
   - `DO NOT REINTRODUCE`
   - `was a prior`
   - `older pack`
   - `no longer`
4. Only after (2)–(3) may you assert "stale" or "wrong comment". Prefer citing  
   the **current** contract in code (`input_mailbox.hpp`, RTL pack site) over  
   rewriting historical notes that already warn correctly.
5. **If you already "fixed" a HISTORICAL block by rewriting it**, restore the  
   author-verified HISTORICAL text unless the technical facts are wrong.

## Gate encoding

`tests/unit/test_comment_context_guard.py` fails the suite if  
`ddr_bank_release_select.hpp` loses its `HISTORICAL FAULT` marker or reintroduces  
a present-tense claim that `frames_done` *is* `bank_vsync_count` outside a  
historical heading.
