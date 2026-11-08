#include <cmath>
#include <cstddef>
#include <cstdlib>

#include <QAction>
#include <QCoreApplication>
#include <QApplication>
#include <QDialog>
#include <QRect>
#include <QScreen>
#include <QFile>
#include <QFont>
#include <QIODevice>
#include <QHBoxLayout>
#include <QLabel>
#include <QSizePolicy>
#include <QStackedWidget>
#include <QtGlobal>
#include <QEvent>
#include <QStringList>
#include <QByteArray>
#include <QMenu>
#include <QPainter>
#include <QPainterPath>
#include <QPen>
#include <QPixmap>
#include <QProcess>
#include <QString>
#include <QVBoxLayout>
#include <QWidget>

#include <NickelHook.h>

#include "recapmod.h"

// Recap, shown in Nickel's OWN dialog.
//
// An earlier attempt created a top-level QWidget and Nickel never routed
// input to it, which wedged the device. Nickel's N3Dialog is the supported
// surface: it owns the window stack, the close button and paging. The
// symbols below were all verified present on firmware 4.46.23836.
//
// Data comes from the existing shell script rather than being reimplemented
// here, so the SQL and the kepub unzip stay in one place.
#define RECAP_LOG    "/mnt/onboard/.adds/Recap/recapmod.log"
#define RECAP_SCRIPT "/mnt/onboard/.adds/Recap/recap.sh"

typedef QDialog N3Dialog;
typedef QWidget MenuTextItem;
typedef QObject MainWindowController;

static struct nh_info RecapModInfo = {
    .name            = "RecapMod",
    .desc            = "Recap in Nickel's own dialog",
    .uninstall_flag  = "/mnt/onboard/RecapMod_uninstall",
    .uninstall_xflag = nullptr,
    .failsafe_delay  = 3,
};

static N3Dialog *(*N3DialogFactory_getDialog)(QWidget *content, bool unknown);
static void (*N3Dialog_setTitle)(N3Dialog *_this, QString const &title);
static void (*N3Dialog_enableFullViewMode)(N3Dialog *_this);
static MainWindowController *(*MainWindowController_sharedInstance)();
static QWidget *(*MainWindowController_pushView)(MainWindowController *mwc, QWidget *view);
static void (*N3ButtonLabel_constructor)(QWidget *_this, QWidget *parent);
static QString (*Content_getId)(void *volume);
static void (*ReadingView_setVolume)(void *_this, void *volume, void *bookmark);
static QString g_currentBook;
static void (*TouchLabel_constructor)(QWidget *_this, QWidget *parent, int windowFlags);
static void (*TouchLabel_setHitStateEnabled)(QWidget *_this, bool enabled);
class ReadingMenuWatcher : public QObject {
public:
    explicit ReadingMenuWatcher(QObject *parent = nullptr) : QObject(parent) {}

protected:
    bool eventFilter(QObject *obj, QEvent *ev) override;
};

// Nickel exposes device-class flags on qApp, so font sizes are declared for
// every class rather than hardcoded for this one. Values follow
// NickelHardcover's own table, which is what makes their dialogs look native.
static const char *kStyle = R"(
  [qApp_deviceIsTrilogy="true"] QLabel { font-size: 19px; }
  [qApp_deviceIsPhoenix="true"]  QLabel { font-size: 23px; }
  [qApp_deviceIsDragon="true"]   QLabel { font-size: 29px; }
  [qApp_deviceIsAlyssum="true"]  QLabel,
  [qApp_deviceIsNova="true"]     QLabel { font-size: 32px; }
  [qApp_deviceIsStorm="true"]    QLabel { font-size: 34px; }
  [qApp_deviceIsDaylight="true"] QLabel { font-size: 37px; }
)";

RecapPager::RecapPager(QStackedWidget *stack, QLabel *counter, int delta, QObject *parent)
    : QObject(parent), m_stack(stack), m_counter(counter), m_delta(delta),
      m_prev(nullptr), m_next(nullptr) {}

void RecapPager::setButtons(QWidget *prev, QWidget *next) {
    m_prev = prev;
    m_next = next;
}

void RecapPager::refresh() {
    const int i = m_stack->currentIndex();
    if (m_prev) m_prev->setVisible(i > 0);
    if (m_next) m_next->setVisible(i < m_stack->count() - 1);
}

void RecapPager::step() {
    const int total = m_stack->count();
    const int i = m_stack->currentIndex() + m_delta;
    if (i >= 0 && i < total) {
        m_stack->setCurrentIndex(i);
        m_counter->setText(QStringLiteral("%1 / %2").arg(i + 1).arg(total));
        refresh();
    }
}

bool RecapPager::eventFilter(QObject *obj, QEvent *ev) {
    const int t = static_cast<int>(ev->type());
    if (t == 3 || t == 196)
        step();
    return QObject::eventFilter(obj, ev);
}

// The class size is unknown, so allocate generously and let Nickel's
// constructor initialise it. This is the trick NickelHardcover uses.
static QWidget *makeButton(QWidget *parent, const QString &text) {
    if (!N3ButtonLabel_constructor)
        return nullptr;
    QWidget *b = reinterpret_cast<QWidget *>(calloc(1, 512));
    N3ButtonLabel_constructor(b, parent);
    b->setProperty("primaryButton", true);
    b->setProperty("text", text);
    return b;
}

static void logline(const QString &s) {
    QFile f(RECAP_LOG);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Append | QIODevice::Text))
        return;
    f.write(s.toUtf8());
    f.write("\n");
    f.flush();
    f.close();
}

static QString recapText() {
    QProcess p;
    QStringList args;
    args << QStringLiteral(RECAP_SCRIPT);
    if (!g_currentBook.isEmpty())
        args << g_currentBook;
    p.start(QStringLiteral("/bin/sh"), args);
    if (!p.waitForFinished(8000))
        return QStringLiteral("The recap script timed out.");
    const QString out = QString::fromUtf8(p.readAllStandardOutput()).trimmed();
    return out.isEmpty() ? QStringLiteral("The recap script produced no output.") : out;
}

static void showRecapDialog() {
    if (!N3DialogFactory_getDialog) {
        logline("FAIL: N3DialogFactory::getDialog not resolved");
        return;
    }

    QWidget *content = new QWidget();
    content->setStyleSheet(QString::fromLatin1(kStyle));
    QVBoxLayout *layout = new QVBoxLayout(content);
    layout->setContentsMargins(28, 24, 28, 44);

    // The script marks its own page breaks. It knows how many table rows it
    // emitted; a line budget here could only guess, and guessed wrong once
    // the cast became a table.
    // The script's first line may be <!--TITLE:escaped book title-->. It
    // becomes the dialog title and is removed from the page text.
    QString text = recapText();
    QString title = QStringLiteral("Recap");
    if (text.startsWith(QStringLiteral("<!--TITLE:"))) {
        const int end = text.indexOf(QStringLiteral("-->"));
        if (end > 0) {
            QString t = text.mid(10, end - 10).trimmed();
            t.replace(QStringLiteral("&lt;"), QStringLiteral("<"));
            t.replace(QStringLiteral("&gt;"), QStringLiteral(">"));
            t.replace(QStringLiteral("&quot;"), QStringLiteral("\""));
            t.replace(QStringLiteral("&#39;"), QStringLiteral("'"));
            t.replace(QStringLiteral("&amp;"), QStringLiteral("&"));
            if (!t.isEmpty())
                title = t;
            text = text.mid(end + 3);
        }
    }

#if QT_VERSION >= QT_VERSION_CHECK(5, 14, 0)
    const auto skipEmpty = Qt::SkipEmptyParts;
#else
    const auto skipEmpty = QString::SkipEmptyParts;
#endif
    QStringList pages;
    foreach (const QString &chunk, text.split(QStringLiteral("<!--PAGE-->"), skipEmpty)) {
        const QString t = chunk.trimmed();
        if (!t.isEmpty())
            pages << t;
    }
    if (pages.isEmpty())
        pages << QStringLiteral("No recap available.");

    QStackedWidget *stack = new QStackedWidget(content);
    for (int i = 0; i < pages.size(); i++) {
        QLabel *page = new QLabel(pages.at(i), stack);
        page->setTextFormat(Qt::RichText);
        page->setWordWrap(true);
        page->setTextInteractionFlags(Qt::NoTextInteraction);
        page->setAlignment(Qt::AlignTop | Qt::AlignLeft);
        stack->addWidget(page);
    }
    layout->addWidget(stack, 1);

    if (pages.size() > 1) {
        QHBoxLayout *nav = new QHBoxLayout();
        QLabel *counter = new QLabel(QStringLiteral("1 / %1").arg(pages.size()), content);
        counter->setAlignment(Qt::AlignCenter);
        QWidget *prev = makeButton(content, QStringLiteral("Back"));
        QWidget *next = makeButton(content, QStringLiteral("More"));
        // Both buttons keep their space when hidden and share one width, so
        // the counter stays centred on the first and last page.
        if (prev && next) {
            const int w = qMax(prev->sizeHint().width(), next->sizeHint().width());
            prev->setFixedWidth(w);
            next->setFixedWidth(w);
        }
        QWidget *buttons[2] = { prev, next };
        for (int k = 0; k < 2; k++) {
            if (!buttons[k]) continue;
            QSizePolicy sp = buttons[k]->sizePolicy();
            sp.setRetainSizeWhenHidden(true);
            buttons[k]->setSizePolicy(sp);
        }
        if (prev) nav->addWidget(prev, 0);
        nav->addStretch(1);
        nav->addWidget(counter, 0);
        nav->addStretch(1);
        if (next) nav->addWidget(next, 0);
        layout->addLayout(nav);

        RecapPager *back = new RecapPager(stack, counter, -1, content);
        RecapPager *fwd = new RecapPager(stack, counter, +1, content);
        back->setButtons(prev, next);
        fwd->setButtons(prev, next);
        if (prev && !QObject::connect(prev, SIGNAL(tapped(bool)), back, SLOT(step())))
            prev->installEventFilter(back);
        if (next && !QObject::connect(next, SIGNAL(tapped(bool)), fwd, SLOT(step())))
            next->installEventFilter(fwd);
        back->refresh();
        logline(QString("paged into %1 pages").arg(pages.size()));
    }

    // Matches NickelHardcover's Dialog constructor. Every step matters:
    // the second argument is true, the dialog must be sized to the screen or
    // it renders as a small box at the top left, it must be pushed onto
    // Nickel's view stack or Nickel never routes touches to it, and
    // closeTapped has to be wired by hand or the close button does nothing.
    N3Dialog *dialog = N3DialogFactory_getDialog(content, true);
    if (!dialog) {
        logline("FAIL: getDialog returned null");
        delete content;
        return;
    }
    if (N3Dialog_setTitle)
        N3Dialog_setTitle(dialog, title);

    QScreen *screen = QApplication::primaryScreen();
    if (screen) {
        const QRect g = screen->geometry();
        dialog->setFixedSize(g.width(), g.height());
        logline(QString("dialog sized %1x%2").arg(g.width()).arg(g.height()));
    }

    if (!MainWindowController_sharedInstance || !MainWindowController_pushView) {
        logline("FAIL: MainWindowController symbols not resolved");
        return;
    }
    MainWindowController *mwc = MainWindowController_sharedInstance();
    if (!mwc) {
        logline("FAIL: sharedInstance returned null");
        return;
    }
    MainWindowController_pushView(mwc, dialog);

    QObject::connect(dialog, SIGNAL(closeTapped()), dialog, SLOT(deleteLater()));
    dialog->show();
    logline("recap dialog pushed and shown");
}

void RecapLauncher::open() { showRecapDialog(); }

static QPixmap recapIcon(int box) {
    QPixmap pm(box, box);
    pm.fill(Qt::transparent);
    QPainter p(&pm);
    p.setRenderHint(QPainter::Antialiasing, true);
    QPen pen(Qt::black);
    pen.setWidth(box / 22 > 1 ? box / 22 : 2);
    pen.setCapStyle(Qt::RoundCap);
    pen.setJoinStyle(Qt::RoundJoin);
    p.setPen(pen);

    const int cx = box / 2;
    const int cy = box / 2;
    const int r = box * 24 / 100;

    QRectF face(cx - r, cy - r, 2.0 * r, 2.0 * r);
    QPainterPath arc;
    arc.arcMoveTo(face, 180.0);
    arc.arcTo(face, 180.0, -270.0);
    p.drawPath(arc);

    const int a = box / 14;
    QPainterPath head;
    head.moveTo(cx - r - a, cy - a);
    head.lineTo(cx - r, cy + a / 3.0);
    head.lineTo(cx - r + a, cy - a);
    p.drawPath(head);

    p.drawLine(cx, cy - r * 55 / 100, cx, cy);
    p.drawLine(cx, cy, cx + r * 50 / 100, cy + r * 35 / 100);
    p.end();
    return pm;
}

// The icon row is a QHBoxLayout on the ReadingMenuView's PARENT, not on
// the view itself, and the new widget goes before the trailing item.
static void injectRecapButton(QWidget *parent) {
    if (!parent || parent->property("recapmod_button").toBool())
        return;
    QHBoxLayout *row = parent->findChild<QHBoxLayout *>(QStringLiteral("bottomHorizontalLayout"));
    QLabel *settingsIcon = parent->findChild<QLabel *>(QStringLiteral("settingsIcon"));
    if (!row || !settingsIcon) {
        logline("FAIL: bottomHorizontalLayout or settingsIcon not found");
        return;
    }
    if (!TouchLabel_constructor) {
        logline("FAIL: TouchLabel constructor not resolved");
        return;
    }

    QLabel *icon = reinterpret_cast<QLabel *>(calloc(1, 512));
    TouchLabel_constructor(icon, parent, 0);
    if (TouchLabel_setHitStateEnabled)
        TouchLabel_setHitStateEnabled(icon, false);
    const int h = settingsIcon->height() > 8 ? settingsIcon->height() : 40;
    icon->setPixmap(recapIcon(h));
    icon->setAlignment(Qt::AlignCenter);

    RecapLauncher *launcher = new RecapLauncher(parent);
    if (!QObject::connect(icon, SIGNAL(tapped(bool)), launcher, SLOT(open()))) {
        logline("FAIL: tapped(bool) did not connect");
        icon->hide();
        return;
    }
    row->insertWidget(row->count() - 1, icon);
    parent->setProperty("recapmod_button", true);
    logline(QString("recap button injected at height %1").arg(h));
}

// NickelHardcover hooks this same constructor and NickelHook resolves the
// original by dlsym rather than chaining, so whichever plugin patches the GOT
// last wins and the other never runs. Watching for the view instead lets both
// mods add an icon.
bool ReadingMenuWatcher::eventFilter(QObject *obj, QEvent *ev) {
    if (ev->type() == QEvent::Show && obj->isWidgetType()
            && qstrcmp(obj->metaObject()->className(), "ReadingMenuView") == 0) {
        QWidget *view = static_cast<QWidget *>(obj);
        QWidget *host = view->parentWidget() ? view->parentWidget() : view;
        injectRecapButton(host);
    }
    return QObject::eventFilter(obj, ev);
}

// The database only learns the open book when it closes, so asking it which
// book is current returns the previous one. Nickel is asked instead.
extern "C" __attribute__((visibility("default")))
void _recap_setvolume_hook(void *_this, void *volume, void *bookmark) {
    if (Content_getId && volume) {
        g_currentBook = Content_getId(volume);
        logline("current book: " + g_currentBook);
    }
    ReadingView_setVolume(_this, volume, bookmark);
}

static int recapInit() {
    QFile::remove(RECAP_LOG);
    if (qApp) {
        qApp->installEventFilter(new ReadingMenuWatcher(qApp));
        logline("mod loaded, watching for ReadingMenuView");
    } else {
        logline("mod loaded, but qApp was null so no button will appear");
    }
    return 0;
}

// NickelMenu injects its own items by hooking createMenuTextItem. Hooking it
// here too silently disabled every NickelMenu entry, because NickelHook
// resolves the original by dlsym rather than chaining. The reading-screen
// button replaced the dropdown item, so this mod no longer touches that symbol.
static struct nh_hook RecapModHook[] = {
    {
        .sym     = "_ZN11ReadingView9setVolumeERK6VolumeRK8Bookmark",
        .sym_new = "_recap_setvolume_hook",
        .lib     = "libnickel.so.1.0.0",
        .out     = nh_symoutptr(ReadingView_setVolume),
        .desc    = "track the open book",
    },
    {0},
};

static struct nh_dlsym RecapModDlsym[] = {
    { .name = "_ZN15N3DialogFactory9getDialogEP7QWidgetb",
      .out  = nh_symoutptr(N3DialogFactory_getDialog),
      .desc = "N3DialogFactory::getDialog" },
    { .name = "_ZN8N3Dialog8setTitleERK7QString",
      .out  = nh_symoutptr(N3Dialog_setTitle),
      .desc = "N3Dialog::setTitle" },
    { .name = "_ZN8N3Dialog18enableFullViewModeEv",
      .out  = nh_symoutptr(N3Dialog_enableFullViewMode),
      .desc = "N3Dialog::enableFullViewMode" },
    { .name = "_ZN20MainWindowController14sharedInstanceEv",
      .out  = nh_symoutptr(MainWindowController_sharedInstance),
      .desc = "MainWindowController::sharedInstance" },
    { .name = "_ZN13N3ButtonLabelC1EP7QWidget",
      .out  = nh_symoutptr(N3ButtonLabel_constructor),
      .desc = "N3ButtonLabel constructor" },
    { .name = "_ZN20MainWindowController8pushViewEP7QWidget",
      .out  = nh_symoutptr(MainWindowController_pushView),
      .desc = "MainWindowController::pushView" },
    { .name = "_ZN10TouchLabelC1EP7QWidget6QFlagsIN2Qt10WindowTypeEE",
      .out  = nh_symoutptr(TouchLabel_constructor),
      .desc = "TouchLabel constructor" },
    { .name = "_ZN10TouchLabel18setHitStateEnabledEb",
      .out  = nh_symoutptr(TouchLabel_setHitStateEnabled),
      .desc = "TouchLabel::setHitStateEnabled" },
    { .name = "_ZNK7Content5getIdEv",
      .out  = nh_symoutptr(Content_getId),
      .desc = "Content::getId" },
    {0},
};

NickelHook(
    .init  = &recapInit,
    .info  = &RecapModInfo,
    .hook  = RecapModHook,
    .dlsym = RecapModDlsym
)
