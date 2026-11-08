# Using Recap

1. Open a book that has recap data embedded (see README).
2. Tap the page to show the reading bar, then tap the **Recap** button.
3. Read the recap. Page through with the dialog's arrows; the cast list is on
   the following pages. Close the dialog to return to your book.

## What you'll see

- **"Last read N day(s) ago"** — from the book's last-read date.
- **"So far in …"** — the chapter you are in, summarised up to your page.
  A passage is included once your bookmark is past its last paragraph, so
  nothing ahead of you is described.
- **"You stopped after …"** — shown instead when you have only just started a
  chapter: the last chapter you finished.
- **"Before that, …"** — the chapter before, for context.
- **"Who you have met"** — everyone who has appeared so far, main character
  first, then by how often they have turned up, with who they are to the main
  character as of your page.
- **"Who you have heard of"** — people only mentioned, talked about or told
  of in a story, from the paragraph that first names them. They move up to
  "met" at the paragraph where they appear.

## Messages

- **"This book has no recap data embedded yet."** — the book carries no
  `recaps/recaps.tsv`. Recaps are generated on a computer and embedded
  before the book goes onto the Kobo.
- **"You are only a few pages in, so there is nothing to recap yet."** — you
  have not finished the first passage yet.
- **"No sqlite3 available."** — install NickelHardcover, or put a `sqlite3`
  binary in `.adds/Recap/`.

## Books from Grimmory and other servers

Books synced from a server work the same as sideloaded ones. They live in
`.kobo/kepub/` under an ID instead of a filename, and Recap finds them there
automatically.
