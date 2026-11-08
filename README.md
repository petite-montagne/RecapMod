# RecapMod

A Kobo mod that tells you what happened last time you picked a book up —
without spoiling the part you haven't read yet.

While reading, tap the **Recap** button in the reading bar. Nickel's own dialog
opens with:

- how long ago you last read the book,
- what has happened so far in the chapter you are in, up to your page, and
  the chapter before it,
- **Who you have met** and **Who you have heard of** — everyone the book has
  named so far, including people only mentioned or told about, with who they
  are to the main character. Nobody is cut off the list.

Only text behind your position is used: a passage counts once your bookmark is
past its last paragraph, and a person appears from the paragraph that first
names them. Books recapped before passages existed still work, a whole chapter
at a time.

Everything works offline. The recaps are written on a computer beforehand and
embedded in each book; nothing is looked up on the device.

## Which books work

Any kepub that carries recap data:

- `recaps/parts.tsv` — passage recaps, each with the paragraph it ends on
- `recaps/people.tsv` — everyone met or heard of, from the paragraph that first
  names them
- `recaps/spine.tsv` — the book's reading order
- `recaps/recaps.tsv` and `recaps/cast.tsv` — chapter-level, for older books

The `recaps/` folder sits beside the book's OPF (`EPUB/`, `OEBPS/`, or the root
— the script finds it). epubkit writes all of these.

Both **sideloaded books** and **books synced from a server** such as Grimmory,
Calibre-Web or Komga are supported. Synced books are stored in
`.kobo/kepub/` under their ContentID rather than as ordinary files; the script
detects this and reads them from there. Nothing needs configuring either way.

Books without recap data, including Kobo store purchases, show a short
"no recap data" message.

## Installing

1. Build `KoboRoot.tgz` (see below), copy it into the hidden `.kobo` folder on
   the Kobo, eject, and let the Kobo install it and restart.
2. Copy `device/recap.sh` to `.adds/Recap/recap.sh` on the Kobo.
3. The script needs `sqlite3`. It uses the copy shipped with NickelHardcover
   (`.adds/NickelHardcover/sqlite3`) if present, otherwise
   `.adds/Recap/sqlite3`, otherwise one on the system path.

Tested on firmware 4.46.23836.

**Uninstalling:** create an empty file named `RecapMod_uninstall` in the root
of the Kobo drive and restart.

**Troubleshooting:** the mod logs to `.adds/Recap/recapmod.log`.

## How it works

The mod is a NickelHook plugin (`src/recapmod.cc`). It hooks
`ReadingView::setVolume` to learn which book is open — the database only
records that when a book is closed — and passes that book's ContentID to
`device/recap.sh`, which reads your position from `KoboReader.sqlite`, reads the
recap data out of the book, and returns the page shown in the dialog.

It deliberately hooks nothing that other mods use: NickelHook resolves hooks
rather than chaining them, so two plugins hooking the same symbol silently
disable each other (NickelMenu and NickelHardcover in particular).

## Building

Needs the NickelTC toolchain with the Kobo Qt 5 sysroot, which runs in Docker
(see `Dockerfile`). `build.sh` sends the sources to the machine that has the
toolchain, builds there, and brings the results back:

```
./build.sh            # librecapmod.so
./build.sh koboroot   # KoboRoot.tgz
./build.sh clean
```

Set `RECAP_BUILD_HOST` to choose the build machine.
