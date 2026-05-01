// pinyin-im.cpp - LD_PRELOAD library for Chinese pinyin input on reMarkable Paper Pro
//
// Intercepts QTextCursor::insertText() calls from the virtual keyboard,
// accumulates pinyin, queries the Go IME server for candidates,
// and commits selected Chinese characters.
//
// Build on build server (192.168.64.4):
//   source ~/opt/codex/chiappa/5.6.75/environment-setup-cortexa55-remarkable-linux
//   $CXX -shared -fPIC -O2 -o libpinyin-im.so pinyin-im.cpp -ldl
//
// Deploy:
//   scp libpinyin-im.so root@10.11.99.1:/home/root/xovi/
//   Add to LD_PRELOAD in xovi.conf
//
// Requires: Go IME server running on 127.0.0.1:19876

#define _GNU_SOURCE
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cctype>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/fb.h>
#include <pthread.h>

#include <QtGui/qtextcursor.h>
#include <QtCore/qstring.h>
#include <QtCore/qbytearray.h>
#include <QtCore/qjsondocument.h>
#include <QtCore/qjsonarray.h>
#include <QtCore/qjsonobject.h>
#include <QtCore/qfile.h>

// ============================================================
// Configuration
// ============================================================
static const char *IME_SERVER_HOST = "127.0.0.1";
static const int IME_SERVER_PORT = 19876;

// ============================================================
// State
// ============================================================
static bool g_pinyinMode = false;
static bool g_committing = false;
static QString g_pinyinBuffer;
static QList<QString> g_candidates;

// Thread safety
static pthread_mutex_t g_stateMutex = PTHREAD_MUTEX_INITIALIZER;

// Check if current keyboard is zh_CN
static bool checkChineseMode() {
    FILE *f = fopen("/home/root/.config/remarkable/xochitl.conf", "r");
    if (!f) return false;

    char line[256];
    bool result = false;
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "Keyboard=zh_CN")) {
            result = true;
            break;
        }
    }
    fclose(f);
    return result;
}

// ============================================================
// HTTP client using raw sockets (no libcurl dependency)
// ============================================================
static QString httpGet(const char *path) {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) return QString();

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(IME_SERVER_PORT);
    inet_pton(AF_INET, IME_SERVER_HOST, &addr.sin_addr);

    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 500000; // 500ms
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        return QString();
    }

    char request[512];
    int len = snprintf(request, sizeof(request),
        "GET %s HTTP/1.0\r\nHost: %s:%d\r\nConnection: close\r\n\r\n",
        path, IME_SERVER_HOST, IME_SERVER_PORT);
    if (send(sock, request, len, 0) < 0) {
        close(sock);
        return QString();
    }

    QByteArray response;
    char buf[4096];
    ssize_t n;
    while ((n = recv(sock, buf, sizeof(buf), 0)) > 0) {
        response.append(buf, n);
    }
    close(sock);

    // Strip HTTP headers
    int bodyStart = response.indexOf("\r\n\r\n");
    if (bodyStart >= 0) {
        response = response.mid(bodyStart + 4);
    }

    return QString::fromUtf8(response);
}

// Parse JSON array response: ["word1","word2","word3"]
static QList<QString> parseCandidates(const QString &json) {
    QList<QString> result;

    QJsonParseError error;
    QJsonDocument doc = QJsonDocument::fromJson(json.toUtf8(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isArray()) {
        return result;
    }

    QJsonArray arr = doc.array();
    for (int i = 0; i < arr.size() && i < 5; i++) {
        result.append(arr[i].toString());
    }
    return result;
}

// ============================================================
// Framebuffer for drawing candidate bar
// ============================================================
static int fb_fd = -1;
static unsigned char *fb_data = nullptr;
static int fb_width = 0;
static int fb_height = 0;
static int fb_stride = 0;

static void fbInit() {
    if (fb_fd >= 0) return;
    fb_fd = open("/dev/fb0", O_RDWR);
    if (fb_fd < 0) return;

    struct fb_var_screeninfo vinfo;
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &vinfo) == 0) {
        fb_width = vinfo.xres;
        fb_height = vinfo.yres;
        fb_stride = vinfo.xres_virtual * (vinfo.bits_per_pixel / 8);
    }

    fb_data = (unsigned char *)mmap(nullptr, fb_height * fb_stride,
        PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
}

// ============================================================
// Check if a character is ASCII letter (potential pinyin)
// ============================================================
static bool isPinyinChar(QChar ch) {
    return ch.isLetter() && ch.unicode() < 128;
}

// ============================================================
// Query IME server for candidates
// ============================================================
static void queryCandidates() {
    QString path = QString("/candidates?pinyin=%1").arg(g_pinyinBuffer);
    QString response = httpGet(qPrintable(path));
    g_candidates = parseCandidates(response);
    g_pinyinMode = !g_candidates.isEmpty();
}

// ============================================================
// Commit a candidate to the text cursor
// ============================================================
static void commitCandidate(QTextCursor *cursor, const QString &text) {
    pthread_mutex_lock(&g_stateMutex);
    g_committing = true;
    g_pinyinBuffer.clear();
    g_candidates.clear();
    g_pinyinMode = false;
    pthread_mutex_unlock(&g_stateMutex);

    cursor->insertText(text);

    pthread_mutex_lock(&g_stateMutex);
    g_committing = false;
    pthread_mutex_unlock(&g_stateMutex);
}

// ============================================================
// Global variables for candidate bar QML communication
// ============================================================
// We'll use a simple approach: write candidates to a file that
// the QML-injected candidate bar reads via XMLHttpRequest
static const char *CANDIDATES_FILE = "/tmp/pinyin_candidates.json";

static void writeCandidatesToFile() {
    QJsonArray arr;
    for (const auto &c : g_candidates) {
        arr.append(c);
    }

    QJsonObject obj;
    obj["pinyin"] = g_pinyinBuffer;
    obj["candidates"] = arr;
    obj["active"] = g_pinyinMode;

    QJsonDocument doc(obj);
    QByteArray data = doc.toJson(QJsonDocument::Compact);

    FILE *f = fopen(CANDIDATES_FILE, "w");
    if (f) {
        fwrite(data.constData(), 1, data.size(), f);
        fclose(f);
    }
}

// ============================================================
// Original function pointer
// ============================================================
typedef void (*insertText_t)(QTextCursor *, const QString &);
static insertText_t real_insertText = nullptr;

// ============================================================
// Hook: QTextCursor::insertText
// ============================================================
extern "C" {

void _ZN11QTextCursor10insertTextERK7QString(QTextCursor *cursor, const QString &text) {
    if (!real_insertText) {
        real_insertText = (insertText_t)dlsym(RTLD_NEXT, "_ZN11QTextCursor10insertTextERK7QString");
    }

    // If we're committing our own candidate, pass through
    pthread_mutex_lock(&g_stateMutex);
    if (g_committing) {
        pthread_mutex_unlock(&g_stateMutex);
        if (real_insertText) real_insertText(cursor, text);
        return;
    }

    // Check if pinyin mode (zh_CN keyboard)
    static bool pinyinEnabled = checkChineseMode();

    if (!pinyinEnabled) {
        pthread_mutex_unlock(&g_stateMutex);
        if (real_insertText) real_insertText(cursor, text);
        return;
    }

    // Handle the intercepted text
    if (text.isEmpty()) {
        pthread_mutex_unlock(&g_stateMutex);
        if (real_insertText) real_insertText(cursor, text);
        return;
    }

    // Check if this is a single ASCII letter (pinyin input)
    if (text.length() == 1 && isPinyinChar(text[0])) {
        QChar ch = text[0].toLower();
        g_pinyinBuffer.append(ch);

        // Query candidates
        queryCandidates();
        writeCandidatesToFile();

        fprintf(stderr, "[pinyin-im] buffer='%s' candidates=%d\n",
                qPrintable(g_pinyinBuffer), g_candidates.size());

        // Don't pass through - we're accumulating pinyin
        pthread_mutex_unlock(&g_stateMutex);
        return;
    }

    // Handle special characters
    if (text == " ") {
        // Space: commit first candidate if available
        if (g_pinyinMode && !g_candidates.isEmpty()) {
            pthread_mutex_unlock(&g_stateMutex);
            commitCandidate(cursor, g_candidates[0]);
            return;
        }
        // No candidates, just pass through
    }

    if (text == "\x7f" || text == "\b") {
        // Backspace
        if (!g_pinyinBuffer.isEmpty()) {
            g_pinyinBuffer.chop(1);
            if (!g_pinyinBuffer.isEmpty()) {
                queryCandidates();
            } else {
                g_candidates.clear();
                g_pinyinMode = false;
            }
            writeCandidatesToFile();
            pthread_mutex_unlock(&g_stateMutex);
            return;
        }
        // No buffer, pass through
    }

    // If we have pending pinyin and user enters something else,
    // commit the raw pinyin buffer first
    if (!g_pinyinBuffer.isEmpty()) {
        pthread_mutex_unlock(&g_stateMutex);
        if (real_insertText) real_insertText(cursor, g_pinyinBuffer);
        g_pinyinBuffer.clear();
        g_candidates.clear();
        g_pinyinMode = false;
        writeCandidatesToFile();
        if (real_insertText) real_insertText(cursor, text);
        return;
    }

    pthread_mutex_unlock(&g_stateMutex);
    if (real_insertText) real_insertText(cursor, text);
}

} // extern "C"

// ============================================================
// Constructor / Destructor
// ============================================================
__attribute__((constructor))
static void init() {
    fprintf(stderr, "[pinyin-im] Library loaded!\n");
    fprintf(stderr, "[pinyin-im] Chinese mode: %s\n", checkChineseMode() ? "YES" : "NO");
    fbInit();
    fprintf(stderr, "[pinyin-im] Framebuffer: %dx%d (stride=%d)\n", fb_width, fb_height, fb_stride);
}

__attribute__((destructor))
static void cleanup() {
    if (fb_data) {
        munmap(fb_data, fb_height * fb_stride);
        fb_data = nullptr;
    }
    if (fb_fd >= 0) {
        close(fb_fd);
        fb_fd = -1;
    }
    fprintf(stderr, "[pinyin-im] Library unloaded\n");
}
