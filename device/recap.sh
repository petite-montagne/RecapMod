#!/bin/sh
# Recap - what you read last time, for Nickel's reader menu.
#
# Reads the recap data embedded in the kepub itself (<opf dir>/recaps/*.tsv)
# and your position from KoboReader.sqlite, and shows only what is behind the
# page you are on.
#
# Position is the spine document AND the koboSpan paragraph of the bookmark
# (ChapterIDBookmarked = OEBPS/ch.xhtml#kobo.N.M). epubkit files every passage
# recap against the paragraph it ends on, and every person against the
# paragraph that first names them, so the comparison is paragraph against
# paragraph - never "the whole chapter" against a guess.
#
# Rows are keyed by spine filename, not by a number, and placed with
# recaps/spine.tsv, so front matter and short interludes do not shift anything.
#
# Older books (recaps.tsv + cast.tsv only, from before passages) still work:
# each chapter is treated as one passage ending on its last paragraph, which
# is exactly the old "only finished chapters" rule.
#
# $1  ContentID of the open book (from the mod). Optional.
# $2  Live position "path#kobo.N.M" (from the mod). Optional; overrides the
#     database, which Nickel only writes when a book is closed or the device
#     sleeps.
#
# Output is HTML for a QLabel. A line containing only <!--PAGE--> starts a new
# page in the dialog. Always exits 0: NickelMenu replaces the output of a
# failing script with an error message.

DB=${RECAP_DB:-/mnt/onboard/.kobo/KoboReader.sqlite}
MAXSUMMARY=600
BIG=100000

SQL=""
for c in /mnt/onboard/.adds/NickelHardcover/sqlite3 /mnt/onboard/.adds/Recap/sqlite3; do
    [ -x "$c" ] && SQL="$c" && break
done
[ -z "$SQL" ] && SQL=$(command -v sqlite3 2>/dev/null)
[ -z "$SQL" ] && { echo "No sqlite3 available. Nothing was read or changed."; exit 0; }

q() { "$SQL" "$DB" "$1" 2>/dev/null; }
esc() { printf '%s' "$1" | sed "s/'/''/g"; }
html() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

clip() {
    awk -v m="${1:-$MAXSUMMARY}" '{
        if (length($0) <= m) { print; next }
        s = substr($0, 1, m)
        p = match(s, /.*[.!?] /)
        if (RSTART > 0 && RLENGTH > m/2) print substr(s, 1, RLENGTH)
        else print s "..."
    }'
}

# $1 is the ContentID the mod read out of Nickel. The DateLastRead fallback is
# one book behind, because the row is only written when a book is closed.
BOOK="${1:-}"
[ -z "$BOOK" ] && BOOK=$(q "SELECT ContentID FROM content WHERE ContentType=6 AND DateLastRead IS NOT NULL ORDER BY DateLastRead DESC LIMIT 1;")
[ -z "$BOOK" ] && { echo "No recently read book found."; exit 0; }
BQ=$(esc "$BOOK")

TITLE=$(q "SELECT Title FROM content WHERE ContentID='$BQ';")
GAP=$(q "SELECT CAST(julianday('now') - julianday(DateLastRead) AS INT) FROM content WHERE ContentID='$BQ';")
MARK="${2:-}"
[ -z "$MARK" ] && MARK=$(q "SELECT ChapterIDBookmarked FROM content WHERE ContentID='$BQ';")
FRAG=$(printf '%s' "$MARK" | sed 's/.*!//; s/#.*//')
PARA=$(printf '%s' "$MARK" | sed -n 's/.*#kobo\.\([0-9][0-9]*\)\..*/\1/p')
SEG=$(printf '%s' "$MARK" | sed -n 's/.*#kobo\.[0-9][0-9]*\.\([0-9][0-9]*\).*/\1/p')

PATHNAME=$(printf '%s' "$BOOK" | sed 's|^file://||')
# Books synced from a server (Grimmory, Calibre-Web, Komga...) are stored the
# way store purchases are: in .kobo/kepub/, named after their ContentID, which
# is not a file:// path. Look there, but only when the file really exists, so
# sideloaded books and setups without a server behave exactly as before.
case "$BOOK" in
    file://*) ;;
    *) [ -f "/mnt/onboard/.kobo/kepub/$BOOK" ] && PATHNAME="/mnt/onboard/.kobo/kepub/$BOOK" ;;
esac

# The recap folder sits beside the OPF, which is EPUB/ in some books and
# OEBPS/ or the zip root in others - so find it rather than assume it.
SRC=""
DIR=""
for cand in "$RECAP_SRC" "$PATHNAME" \
            "$(printf '%s' "$PATHNAME" | sed 's/\.kepub\.epub$/_with_ai_recaps.kepub.epub/')" \
            "$(printf '%s' "$PATHNAME" | sed 's/\.kepub\.epub$/_with_recaps.kepub.epub/')"; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    hit=$(unzip -l "$cand" 2>/dev/null | awk '{print $NF}' | grep -E 'recaps/(parts|recaps)\.tsv$'  | awk -F/ '$NF=="parts.tsv" {print; f=1; exit} {r=r?r:$0} END{if(!f && r) print r}')
    if [ -n "$hit" ]; then
        SRC="$cand"
        DIR="${hit%/*}/"
        break
    fi
done
[ -z "$SRC" ] && {
    printf '<!--TITLE:%s-->\n' "$(printf '%s' "$TITLE" | html)"
    printf '<p style="font-family:Georgia,serif; color:#000000; line-height:150%%">This book has no recap data embedded yet.</p>\n'
    exit 0
}

get() { unzip -p "$SRC" "${DIR}$1" 2>/dev/null; }

PARTS=$(get parts.tsv)
if [ -z "$PARTS" ]; then
    # older book: a chapter is one passage that ends with the chapter
    PARTS=$(get recaps.tsv | awk -F'\t' -v big="$BIG" 'NF>=4 {printf "%s\t%s\t%d\t%s\t%s\n", $1, $2, big-1, $3, $4}')
fi
SPINE=$(get spine.tsv)

# ---------------------------------------------------------------- position
# ORDER is the spine position of the bookmarked document; POS is that and the
# paragraph together, as one number to compare against every row.
ORDER=$(printf '%s\n' "$SPINE" | awk -F'\t' -v f="$FRAG" '$2==f {print $1; exit}')
[ -z "$ORDER" ] && ORDER=$(printf '%s\n' "$PARTS" | awk -F'\t' -v f="$FRAG" '$2==f {print $1; exit}')
if [ -z "$ORDER" ]; then
    # no spine list and no recap for this document: the last one sorting
    # before it by name is the best guess, and it errs early, never late
    # - so place the reader just past the end of that document
    GUESS=$(printf '%s\n' "$PARTS" | awk -F'\t' -v f="$FRAG" '$2"" < f"" {p=$1} END{print (p=="" ? -1 : p)}')
    ORDER=$((GUESS + 1))
    PARA=-1
fi
[ -z "$PARA" ] && PARA=0
POS=$((ORDER * BIG + PARA))

if [ "$GAP" -eq 1 ] 2>/dev/null; then
    WHEN="Last read 1 day ago"
elif [ "$GAP" -gt 1 ] 2>/dev/null; then
    WHEN="Last read $GAP days ago"
else
    WHEN="Last read today"
fi

# passages fully behind you: order, label, summary - oldest first
BEHIND=$(printf '%s\n' "$PARTS" | awk -F'\t' -v pos="$POS" -v big="$BIG" \
         'NF>=5 && ($1 * big + $3) <= pos {printf "%s\t%s\t%s\n", $1, $4, $5}')
LAST=$(printf '%s\n' "$BEHIND" | awk -F'\t' 'NF {o=$1} END{print o}')
CURLABEL=$(printf '%s\n' "$PARTS" | awk -F'\t' -v o="$ORDER" '$1==o {print $4; exit}')

# In the chapter you are in: the passage just behind your page on its own,
# and the ones before it together
NOW=""
EARLIER=""
if [ "$LAST" = "$ORDER" ]; then
    NOW=$(printf '%s\n' "$BEHIND" | awk -F'\t' -v o="$ORDER" '$1==o {s=$3} END{print s}')
    EARLIER=$(printf '%s\n' "$BEHIND" | awk -F'\t' -v o="$ORDER" '$1==o {if (p!="") printf "%s ", p; p=$3}')
fi
# and the chapter before that, whole
PREV=$(printf '%s\n' "$BEHIND" | awk -F'\t' -v o="$ORDER" 'NF && $1 < o {p=$1} END{print p}')
PLABEL=""
PSUMMARY=""
if [ -n "$PREV" ]; then
    PLABEL=$(printf '%s\n' "$BEHIND" | awk -F'\t' -v o="$PREV" '$1==o {print $2; exit}')
    PSUMMARY=$(printf '%s\n' "$BEHIND" | awk -F'\t' -v o="$PREV" '$1==o {print $3}' | tr '\n' ' ')
fi
EARLIER=$(printf '%s' "$EARLIER" | clip | html)
PSUMMARY=$(printf '%s' "$PSUMMARY" | clip | html)

# The line your page starts on, lifted out of the book itself: the koboSpan
# the bookmark names and the rest of its paragraph. No model wrote this, so
# it is exact, and it costs nothing to store. Entities are left as they are;
# the dialog renders them.
LINE=""
if [ -n "$PARA" ] && [ -n "$SEG" ] && [ "$PARA" -ge 0 ] 2>/dev/null; then
    LINE=$(unzip -p "$SRC" "$FRAG" 2>/dev/null | tr '\n' ' ' \
           | grep -o "id=\"kobo\.$PARA\.[0-9]*\"[^>]*>[^<]*" \
           | sed 's/^id="kobo\.[0-9]*\.\([0-9]*\)"[^>]*>/\1	/' \
           | awk -F'\t' -v m="$SEG" -v max=240 '
               $1+0 >= m { t = t $2 }
               END {
                   gsub(/  +/, " ", t); sub(/^ /, "", t)
                   if (length(t) > max) { t = substr(t, 1, max); sub(/ [^ ]*$/, "", t); t = t "..." }
                   print t
               }')
fi

# ---------------------------------------------------------------- layout
# One look: Georgia (Nickel falls back to its default serif), black text,
# small upper-case labels, 150% body lines, one rule. Page 1 runs in story
# order and always ends on PICK UP HERE, the place the reader goes back to.
#
# Page budget, in tenths of a body line. A Clara-class screen (1072x1448,
# 300 ppi) gives the label about 1448 - 130 title bar - 68 margins - 110 nav
# = ~1140 px of height and ~970 px of width. At the 34 px body size and 150%
# leading that is 22 lines of about 56 Georgia characters; one line is held
# back for rounding, because overflowing is worse than a short page.
BUDGET=210
LINECOLS=56
LABEL=15        # 70% text plus the space above it
RULE=10
FONT='font-family:Georgia,serif; color:#000000'

lines() { echo $(( ( ${#1} + LINECOLS - 1) / LINECOLS * 10 )); }
upper() { awk '{print toupper($0)}'; }
label() { printf '<p style="%s; font-size:70%%; margin:18px 0px 4px 0px">%s</p>\n' "$FONT" "$(printf '%s' "$1" | upper | html)"; }
meta() { printf '<p style="%s; font-size:70%%; margin:0px 0px 4px 0px">%s</p>\n' "$FONT" "$(printf '%s' "$1" | upper | html)"; }
body() { printf '<p style="%s; margin:0px; line-height:150%%">%s</p>\n' "$FONT" "$1"; }
rule() { printf '<hr>\n'; }

USED=0
newpage() { printf '\n<!--PAGE-->\n'; USED=0; }
room() { if [ $((USED + $1)) -gt "$BUDGET" ] && [ "$USED" -gt 0 ]; then newpage; fi; USED=$((USED + $1)); }

# The line the page starts on, without the book's own quote marks, so it is
# not quoted twice.
LINE=$(printf '%s' "$LINE" | sed -e 's/^ *//; s/ *$//' \
       -e 's/^\(&quot;\|&#8220;\|&#x201[cC];\|&ldquo;\|&#8216;\|&lsquo;\|“\|‘\|"\|'"'"'\)*//' \
       -e 's/\(&quot;\|&#8221;\|&#x201[dD];\|&rdquo;\|&#8217;\|&rsquo;\|”\|’\|"\|'"'"'\)*$//')

pickup() {
    if [ -n "$LINE" ]; then
        label "Pick up here"
        printf '<p style="%s; margin:0px; line-height:150%%"><i>&#8220;%s&#8221;</i></p>\n' "$FONT" "$LINE"
    fi
}
PICK=0
[ -n "$LINE" ] && PICK=$((RULE + LABEL + $(lines "$LINE")))

printf '<!--TITLE:%s-->\n' "$(printf '%s' "$TITLE" | html)"

if [ -n "$CURLABEL" ]; then META="$CURLABEL · $WHEN"; else META="$WHEN"; fi
meta "$META"
USED=$LABEL

if [ -n "$NOW" ]; then
    # Just-before plus the pick-up line must fit; clip the passage if not.
    ROOM=$(( (BUDGET - USED - LABEL - PICK) / 10 * LINECOLS ))
    [ "$ROOM" -lt 120 ] && ROOM=120
    NOW=$(printf '%s' "$NOW" | clip "$ROOM" | html)
    NEED=$((LABEL + $(lines "$NOW") + PICK))
    SPILL=""
    if [ -n "$EARLIER" ]; then
        if [ $((USED + LABEL + $(lines "$EARLIER") + NEED)) -le "$BUDGET" ]; then
            label "Earlier in $CURLABEL"
            body "$EARLIER"
            USED=$((USED + LABEL + $(lines "$EARLIER")))
        else
            SPILL=1
        fi
    fi
    label "Just before your page"
    body "$NOW"
    [ -n "$LINE" ] && { rule; pickup; }
    USED=$BUDGET
    if [ -n "$SPILL" ]; then
        newpage
        label "Earlier in $CURLABEL"
        body "$EARLIER"
        USED=$((LABEL + $(lines "$EARLIER")))
    fi
    if [ -n "$PSUMMARY" ]; then
        room $((LABEL + $(lines "$PSUMMARY")))
        label "Further back · $PLABEL"
        body "$PSUMMARY"
    fi
elif [ -n "$PSUMMARY" ]; then
    label "$PLABEL"
    body "$PSUMMARY"
    [ -n "$LINE" ] && { rule; pickup; }
else
    printf '<p style="%s; margin:12px 0px 0px 0px; line-height:150%%">You are only a few pages in, so there is nothing to recap yet.</p>\n' "$FONT"
    [ -n "$LINE" ] && { rule; pickup; }
fi
exit 0
