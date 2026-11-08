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
HALFLINES=30
LINECOLS=58
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
    awk -v m="$MAXSUMMARY" '{
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
    hit=$(unzip -l "$cand" 2>/dev/null | awk '{print $NF}' | grep -E 'recaps/(parts|recaps)\.tsv$' | head -n 1)
    if [ -n "$hit" ]; then
        SRC="$cand"
        DIR="${hit%/*}/"
        break
    fi
done
[ -z "$SRC" ] && { printf '<p><b>%s</b></p><p>This book has no recap data embedded yet.</p>\n' "$(printf '%s' "$TITLE" | html)"; exit 0; }

get() { unzip -p "$SRC" "${DIR}$1" 2>/dev/null; }

PARTS=$(get parts.tsv)
if [ -z "$PARTS" ]; then
    # older book: a chapter is one passage that ends with the chapter
    PARTS=$(get recaps.tsv | awk -F'\t' -v big="$BIG" 'NF>=4 {printf "%s\t%s\t%d\t%s\t%s\n", $1, $2, big-1, $3, $4}')
fi
# people: order, path, paragraph, name, met|heard, times seen, description
PEOPLE=$(get people.tsv)
if [ -z "$PEOPLE" ]; then
    PEOPLE=$(get cast.tsv | awk -F'\t' -v big="$BIG" 'NF>=4 {n[$3]++; printf "%s\t%s\t%d\t%s\tmet\t%d\t%s\n", $1, $2, big-1, $3, n[$3], $4}')
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

if [ "$GAP" -gt 0 ] 2>/dev/null; then
    WHEN="Last read $GAP day(s) ago"
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
NOW=$(printf '%s' "$NOW" | html)
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

SANS='font-family:sans-serif'
USED=0
line_cost() { echo $(( ($1 + LINECOLS - 1) / LINECOLS )); }
# page break when the next block will not fit on this page
room() {
    if [ $((USED + $1)) -gt "$HALFLINES" ] && [ "$USED" -gt 0 ]; then
        printf '\n<!--PAGE-->\n'
        USED=0
    fi
    USED=$((USED + $1))
}
small() { room 2; printf '<p style="%s; font-size:68%%; color:#666666; margin:0px 0px 12px 0px">%s</p>' "$SANS" "$1"; }
head1() { printf '<p style="%s; font-size:124%%; margin:0px"><b>%s</b></p>' "$SANS" "$1"; }
body() { printf '<p style="margin:0px; line-height:152%%">%s</p>' "$1"; }
sub1() { printf '<p style="%s; font-size:84%%; margin:24px 0px 8px 0px"><b>%s</b></p>' "$SANS" "$1"; }

small "$(printf '%s' "$WHEN" | tr '[:lower:]' '[:upper:]')"
if [ -n "$LINE" ]; then
    room $(( 3 + 2 * $(line_cost ${#LINE}) ))
    sub1 "Your page begins"
    printf '<p style="margin:0px; line-height:152%%"><i>&#8220;%s&#8221;</i></p>' "$LINE"
fi
if [ -n "$NOW" ]; then
    room $(( 4 + 2 * $(line_cost ${#NOW}) ))
    head1 "Just before your page"
    printf '<p style="font-size:84%%; color:#666666; margin:5px 0px 0px 0px">%s</p><hr>' \
        "$(printf '%s' "$CURLABEL" | html)"
    body "$NOW"
    if [ -n "$EARLIER" ]; then
        room $(( 3 + 2 * $(line_cost ${#EARLIER}) ))
        sub1 "Earlier in $(printf '%s' "$CURLABEL" | html)"
        body "$EARLIER"
    fi
    if [ -n "$PSUMMARY" ]; then
        room $(( 3 + 2 * $(line_cost ${#PSUMMARY}) ))
        sub1 "Before that, $(printf '%s' "$PLABEL" | html)"
        printf '<p style="font-size:89%%; color:#555555; margin:0px; line-height:152%%">%s</p>' "$PSUMMARY"
    fi
elif [ -n "$PSUMMARY" ]; then
    room $(( 4 + 2 * $(line_cost ${#PSUMMARY}) ))
    head1 "You stopped after $(printf '%s' "$PLABEL" | html)"
    if [ -n "$CURLABEL" ]; then
        printf '<p style="font-size:84%%; color:#666666; margin:5px 0px 0px 0px">You have just started %s.</p>' \
            "$(printf '%s' "$CURLABEL" | html)"
    fi
    printf '<hr>'
    body "$PSUMMARY"
else
    room 4
    head1 "$(printf '%s' "$TITLE" | html)"
    printf '<p style="margin-top:12px">You are only a few pages in, so there is nothing to recap yet.</p>'
fi

# ---------------------------------------------------------------- who's who
# Everyone whose first mention is at or before your page. Per person: the
# latest status (met beats heard) and the latest description at or before
# your page, ranked by how many passages they have turned up in so far -
# recency buried the leads (Harry ranked 81st of 83 by chapter 13 of book 5).
# Met and heard-of are listed separately; nobody is cut off the list.
CAST=$(printf '%s\n' "$PEOPLE" \
       | awk -F'\t' -v pos="$POS" -v big="$BIG" '
         function clean(t,   low, p) {
             low = tolower(t)
             if (low !~ FATE) return t
             p = index(low, " who ")
             if (p < 2) p = index(low, ", ")
             if (p < 2) return ""
             t = substr(t, 1, p - 1)
             sub(/[ ,]+$/, "", t)
             if (tolower(t) ~ FATE) return ""
             return t
         }
         BEGIN {
             FATE = "kill|dies|died|murder|betray|traitor|reveal|turns out|secretly|is actually|later becomes|will be|survives|sacrific|tortur|imprison|executed|doomed|his fate|her fate|their fate"
         }
         NF >= 6 && ($1 * big + $3) <= pos {
             nm = $4
             if (!(nm in seen)) order[++c] = nm
             # 7 columns carry a running count; the first passage layout had
             # 6 and one row per appearance, so count the rows instead
             if (NF >= 7) { seen[nm] = $6 + 0; desc = $7 } else { seen[nm]++; desc = $6 }
             if ($5 == "met") met[nm] = 1
             t = clean(desc)
             if (t != "") d[nm] = t
             if (t == "the main character") hero[nm] = 1
         }
         END {
             for (i = 1; i <= c; i++) {
                 nm = order[i]
                 rank = (nm in hero) ? 99999999 : seen[nm] * 10000 + (c - i)
                 printf "%s\t%d\t%s\t%s\n", (nm in met) ? "met" : "heard", rank, nm,
                        (nm in d ? d[nm] : "")
             }
         }' | sort -t "$(printf '\t')" -k2,2nr)

render() {
    # $1 = met|heard, $2 = heading; pages itself against the line budget
    rows=$(printf '%s\n' "$CAST" | awk -F'\t' -v s="$1" '$1==s {printf "%s\t%s\n", $3, $4}')
    n=$(printf '%s\n' "$rows" | grep -c .)
    [ "$n" -eq 0 ] 2>/dev/null && return
    printf '\n<!--PAGE-->\n'
    small "$2 ($n)"
    printf '%s\n' "$rows" | html \
        | awk -F'\t' -v budget="$HALFLINES" -v w="$LINECOLS" '
            function rows(t,   k) { k = int((length(t) + w - 1) / w); return k < 1 ? 1 : k }
            BEGIN { used = 5; pending = 0 }
            NF {
                cost = 2 * rows($1 "  " $2) + 1
                if (used + cost > budget) {
                    print ""
                    print "<!--PAGE-->"
                    used = 0
                    pending = 0
                }
                if (pending) print "<hr>"
                printf "<p style=\"margin:0px 0px 12px 0px; line-height:148%%\"><b style=\"font-family:sans-serif; font-size:92%%\">%s</b>&nbsp;&nbsp;%s</p>\n", $1, $2
                pending = 1
                used += cost
            }'
}

render met "WHO YOU HAVE MET"
render heard "WHO YOU HAVE HEARD OF"
exit 0
