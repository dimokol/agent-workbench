## Product copy voice

The writing-tone block (https://github.com/dimokol/agent-workbench/blob/main/blocks/writing-tone.md) sets the
base rules for how an agent writes. A product's user-facing copy also needs a voice of its own,
tuned to who reads it and what they need at each moment. This is one worked example, for a service
product used by a broad, non-technical audience. Run the same method on your own product and keep
the rules that fit.

Answer three questions before writing a single string.

1. **Who reads this copy, and what do they already know?** A checkout flow used by anyone off
   the street reads differently from a developer dashboard. Name the audience honestly, and
   write for the least technical reader you expect rather than the median one.
2. **What does the copy need to do at each moment?** Confirm an action, explain a consequence,
   recover from an error, label a control. Each of those is a different job, so they shouldn't
   all sound the same.
3. **What's the one failure mode to design against?** For this example, it's a user who doesn't
   understand what they just clicked, or who feels talked down to. Your failure mode shapes
   every rule that follows.

### The voice for this example

- Use short sentences, plain words and one idea per line. If a message needs a paragraph,
  rethink the flow before adding copy.
- Sound like a helpful person at a front desk, warm and professional. Leave out sales talk and
  cute jokes.
- Write what a person would say out loud to the reader. "Booking record updated" reads like a
  log line. "We've changed your booking" reads like a person.

### Explain without talking down

- Say what an action does and what happens next, especially before anything irreversible
  (cancel, pay, confirm, delete).
- Explain once. Don't repeat the heading in the text under it, and skip "as you may know".
- Plan for elderly and non-technical readers from the start. Keep jargon and internal terms
  (payload, token, raw field names) out of every string, and name things the way the reader
  would ("your booking", "your email").
- On errors, say what happened and what to do next, in plain words. Never show a raw error code
  as the whole message, and never blame the reader. "That card number is too short. Check the
  last few digits." tells them the fix, where "You entered an invalid value" only scolds.

### Plain language for everyone

- Prefer the common word over the clever one. Label a control with what it does ("Confirm
  booking" instead of a bare "Submit").
- If the product ships in more than one language, give each language the same care, and check
  that the longest one still fits tight spaces like buttons, chips and small screens.
- Write dates, times, prices and durations in a full form the least technical reader can parse
  at a glance, such as "Thursday 14 May, 18:30".

### Other products answer differently

This example keeps one plain register throughout, because its audience and failure mode call
for it. Another product could answer the same three questions differently. A game or a
character-driven assistant might run two registers: an in-character voice for flavor text, and
a plain, unambiguous one for anything transactional (payments, permissions, data).
