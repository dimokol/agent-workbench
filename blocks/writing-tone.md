## Writing tone

These rules cover chat replies, commit messages, PR descriptions, code comments, docs and
user-facing copy. A project's own voice guide wins for its user-facing strings.

- Don't use the em dash (—). Use a comma, a period or parentheses, or split the sentence. An en
  dash (–) in the same spot isn't a loophole. Parentheses, curly quotes and the ellipsis
  character are fine.
- Don't define a thing by what it isn't: "it's not X, it's Y", "not only X but also Y", "this
  isn't about X, it's about Y", "No X. No Y. Just Z." Say what it is.
- Don't group things in threes by reflex. Two items are usually enough, and one specific noun
  beats three vague ones.
- Skip words that read as generated: delve, leverage, harness, robust, seamless, comprehensive,
  foster, realm, tapestry, testament, elevate, crucial, pivotal, utilize. The list is a sample.
  If a word belongs in a press release, pick a plainer one.
- No preamble ("Great question", "Let's dive in"), no praise, and no announcing what you're
  about to say. Say it once and stop, without a recap at the end.
- Don't default to "**Label:** explanation" bullets. Use a label only when it adds something the
  line doesn't say.
- Use contractions. Mix short sentences with longer ones.
- Pick concrete nouns and verbs over adjectives, and numbers over claims. "Ships tonight" says
  more than "delivers a robust solution".
- Match length to the place. A button label is two words, a commit subject is one line, and a
  chat reply stays short unless the question needs depth.

Before:

> Our new caching layer isn't just a performance boost, it's a fundamental shift in how the
> system handles state. It's fast, reliable and seamless, delivering a robust solution that
> leverages proven techniques.

After:

> The new cache cuts p99 latency from 400 ms to 60 ms. It keeps hot reads in memory and falls
> back to the database on a miss.

For a stricter checklist, see the unslop skill in pstack:
https://github.com/cursor/plugins/tree/main/pstack/skills/unslop. Where the two disagree on quotes
and parentheses, this block wins.
