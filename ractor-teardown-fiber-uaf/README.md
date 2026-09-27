# Ruby: use-after-free of a dying Ractor thread's fiber (rb_current_ractor_raw)

Pre-existing race on current Ruby master (`da3e1fcb68`, 2026-09-25).  Not
caused by any of our PRs; it is what the `ubuntu-24.04` ASan + `USE_MN_THREADS=0`
CI job hit on ruby/ruby#19048.  The new `TestGc#test_stat_global_scope_retains_finished_ractor_history`
(test added by `60c206b683` "Add global scope to GC.stat", 2026-09-23) is just
the first test to exercise it.

## Reproducer

`repro_loop.rb` — the test's own inner script in a loop.  `run.sh` drives it.

Needs an ASan build configured like the CI job:

    ./configure --disable-install-doc \
        CC=clang cflags=-fsanitize=address cppflags=-DUSE_MN_THREADS=0
    make -j

Then:

    RUBY_ASAN=/path/to/ruby PAR=8 ./run.sh

**Result (this machine, 2026-09-26): 8/8 parallel runs fail** with

    ==...==ERROR: AddressSanitizer: heap-use-after-free ... in rb_current_ractor_raw

after ~40,000–50,000 loop iterations each (≈2 minutes).  Full report in
`asan-report.txt`.

## What is freed, and by whom

- Bad read: 8 bytes at offset 136 of a **664-byte** region freed by the GC
  (`rb_gc_impl_free` ← `ruby_xfree_sized`).  `sizeof(rb_fiber_t) == 664`, and the
  fiber embeds the thread's final EC (`fiber_ptr`/`thread_ptr`), so the freed
  region is the dying thread's `rb_fiber_t`.
- Freeing thread: **T0**, the main thread running `GC.start`.
- Crashing thread: **T2**, the Ractor's own native thread, in
  `thread_start_func_2` → `rb_ractor_living_threads_remove` → `vm_remove_ractor`
  → `rb_gc_objspace_retire` → `RB_VM_LOCKING()` → `vm_locked()` →
  `rb_current_ractor()` → `GET_EC()->thread_ptr` on the freed fiber.

## Root cause

`ractor_postmortem_collect()` (`ractor.c:715`) runs on the dying thread before
`vm_remove_ractor()` and sets

    cr->postmortem = rb_gc_multi_objspace_p() && !rb_thread_event_hooks_registered_p();

With the default multi-objspace GC and no thread-event hooks, this is **true**.
`rb_ractor_mark_local_roots()` (`ractor.c:348`) then takes the `r->postmortem`
branch (`ractor.c:350`), which deliberately **skips** `ractor_mark_unshareable_parts(r)`
— i.e. it stops marking the Ractor's Thread and Fiber wrappers, on the theory
that the final self-collection is about to reclaim them:

    if (r->postmortem) {
        /* The final self collection: everything else -- the Thread and Fiber
         * wrappers, stdio, stack leftovers -- is what it exists to reclaim. ... */
        ...
        return;
    }

But the flag is set while the Ractor's last thread is **still executing the
native epilogue** in `thread_start_func_2` (`thread.c:874-885`), which keeps
using the thread's EC (via `GET_RACTOR()`/`GET_EC()`, reached through
`rb_ractor_living_threads_remove` → `vm_remove_ractor` → `rb_gc_objspace_retire`).
Any concurrent GC in that window frees the unmarked fiber and the epilogue
dereferences it.  `ractor_postmortem_collect` also only takes ownership of the
fiber for `rb_ractor_postmortem_free()` when the Fiber wrapper is already gone
(`pf->fiber = (fiber_wrapped && rb_fiberptr_self(fiber) == 0) ? fiber : NULL`);
otherwise it leaves the struct to the GC, which frees it too early.

`vm_remove_ractor` reaching `rb_gc_objspace_retire` at all proves
`rb_gc_multi_objspace_p()` is true on this build (the function returns early
otherwise), so the `postmortem` branch is live.

## Fix attempt 1 — failed

`fix-attempt-1-retire-before-unlink.patch`: move the `rb_gc_objspace_retire()`
call in `vm_remove_ractor` to before `ccan_list_del(&cr->vmlr_node)`, so the
Ractor is still in `vm->ractor.set` when it retires.  **Did not help**: 8/8
still fail at the same stack — Ractor-set membership is not what roots the
fiber once `r->postmortem` is set (the `postmortem` branch discards the set
walk regardless).

## Status

- Reliable reproducer: **yes** (8/8 within ~2 min).
- Root cause: identified (above).
- Fix: not done.  The correct fix has to keep the dying thread's Fiber/EC alive
  until `thread_start_func_2`'s epilogue finishes — either by not setting
  `postmortem` until then, by marking the running thread specially in the
  `postmortem` branch, or by having `ractor_postmortem_collect` take ownership
  of the fiber unconditionally.  This is core thread/Ractor teardown code under
  active development (Koichi Sasada, Matt Valentine-House) and needs their
  review; do not post a speculative patch.
