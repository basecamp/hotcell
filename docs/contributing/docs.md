---
type: Contributing
title: "Keep the docs current"
order: 2
description: "The rake docs tasks, the order to run them in before a pull request, and the tests that hold tables to the code."
sources:
  - rakelib/docs.rake
  - hotcell-core/test/docs_test.rb
  - hotcell-server/test/docs_test.rb
  - activestorage-hotcell-server/test/docs_test.rb
---

# Keep the docs current

The reference pages describe behavior, so a change to the code can make a page wrong. Treat the docs as
part of the change:

1. Before you open a pull request, run `rake docs:stale`. It lists each page whose `sources` you changed
   while the page didn't change. Read each page it names, and update what your change made wrong. A page
   that's still right needs no edit. CI prints the same list as warnings on the pull request.
2. When a page starts or stops describing a file, add it to or remove it from the page's `sources`. A
   source can be a file or a directory.
3. When you add a page or change a page's `title` or `description`, run `rake docs:index` to regenerate
   the page lists in every `index.md`.
4. Run `rake docs:check`. It fails on a page without `type`, `title`, or `description`, on a source that
   doesn't exist, and on an index that's out of date. CI runs it on every push, and so does `rake`.

Some tables are held to the code by tests, which fail when the two disagree:

| Table | Test |
| --- | --- |
| Codes and kill causes in `docs/codes.md` | `hotcell-core/test/docs_test.rb` |
| Events in `docs/observability.md`, and defaults in `docs/cell-settings.md` | `hotcell-server/test/docs_test.rb` |
| Shipped operation limits in `docs/active-storage.md` | `activestorage-hotcell-server/test/docs_test.rb` |
