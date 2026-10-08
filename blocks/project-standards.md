## Latency budget

No query, mutation or endpoint takes longer than 500 ms on production-like data from the
heaviest account you have. Uploads, exports and calls to outside services get their own budget.

- Measure the real response time in the network panel or the server's timing logs. A page that
  renders fast can still be waiting on a slow request.
- A page is fast only when every request it fires is under budget.
- When something is over budget, find the cause before adding a spinner. The usual ones are too
  many rows, too many fields, a total computed in application code instead of the database, and
  one query per row (N+1).

## Pagination

- Every list that grows with use is paginated on the server, with offset and limit or a cursor,
  plus a count query when the UI shows a total.
- Default page size is 20 and the hard maximum is 50. If a caller asks for more, clamp it to the
  maximum. Don't throw an error and don't load everything.
- Sort on a unique tie-breaker as the last key (for example `createdAt`, then `id`). Without it,
  rows with equal sort values can repeat or vanish between pages.
- Treat an unbounded fetch (`limit: 1000`, or no limit at all) as a bug in review. It works on
  test data, then times out or runs out of memory on real data.

## Search

- Search runs on the server, as a query with a search argument. Never filter a paginated list in
  the browser. It only sees the current page, so it silently misses everything else.
- Start searching at 3 characters and debounce input by 300 ms. Firing a query on every
  keystroke, or for one or two characters, loads the database for nothing.
- Ignore responses for an older search term. Otherwise a slow early response can land after a
  fast later one and show results for the wrong text.

## Counts and totals

Compute every statistic (dashboard counters, per-account totals, anything added later) in the
database with an aggregation or a grouped query. Never fetch rows and sum them in application
code. With pagination in place that sum is also wrong, because it only covers the rows on the
current page.

## One source for each repeated value

- A value or block that appears in more than one place (a color, a limit, a label, a component)
  comes from one constant, token or component, so changing it takes one edit.
- Before adding something that looks like an existing pattern, search for its constant or
  component and reuse it. Assume it exists until the search says otherwise.
- If a value is going to repeat, pull it out now. "Centralize it later" rarely happens, and the
  copies drift apart in the meantime.
- A new instance of a pattern matches its siblings in naming, spacing and structure.

## Comments

- Delete commented-out code. Version control keeps it.
- Update or delete a comment in the same change as the code it describes. A stale comment sends
  the next reader the wrong way.

## Before calling UI work done

- Look at it in a browser at a phone width and a desktop width. A passing typecheck says nothing
  about layout.
- Use real `button`, `a` and `label` elements. Every control works with the keyboard alone and
  shows a visible focus ring.
- Body text meets WCAG AA contrast (4.5:1).
- Animation respects `prefers-reduced-motion`.
- Large images, video and 3D load lazily or after an interaction.
