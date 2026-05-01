// pinyin-intercept.cpp - LD_PRELOAD library to intercept virtual keyboard input
// and route through the Go IME pinyin service
//
// Target: reMarkable Paper Pro (aarch64, Qt 6.8.2)
// Build: aarch64-linux-gnu-g++ -shared -fPIC -o libpinyin-intercept.so pinyin-intercept.cpp -ldl -lcurl

#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <curl/curl.h>
#include <string>
#include <vector>

// ============================================================
// QTextCursor minimal declarations (from Qt6Gui)
// ============================================================
namespace Qt {
    enum KeyboardModifier {
        NoModifier = 0x00000000,
        ShiftModifier = 0x02000000,
        ControlModifier = 0x04000000,
        AltModifier = 0x08000000,
    };
}

class QString {
public:
    QString() {}
    QString(const char *s);
    // We won't define the full API - we just need the type for hooking
};

class QTextCursor {
public:
    void insertText(const QString &text);
};

class QInputMethod {
public:
    static QInputMethod *instance();
    bool isVisible() const;
};

// ============================================================
// State
// ============================================================
static bool g_intercepting = true;
static bool g_committing = false;  // true when committing a candidate (skip interception)

static std::string g_pinyinBuffer;
static std::vector<std::string> g_candidates;
static bool g_pinyinActive = false;

static const char *IME_SERVER = "http://127.0.0.1:19876";

// ============================================================
// HTTP client (using libcurl)
// ============================================================
static std::string httpGet(const std::string &url) {
    CURL *curl = curl_easy_init();
    if (!curl) return "";

    std::string response;
    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 500L);
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, +[](char *ptr, size_t size, size_t nmemb, void *userdata) -> size_t {
        std::string *resp = static_cast<std::string *>(userdata);
        resp->append(ptr, size * nmemb);
        return size * nmemb;
    });
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_perform(curl);
    curl_easy_cleanup(curl);
    return response;
}

// Simple JSON array parser for ["word1","word2","word3"]
static std::vector<std::string> parseCandidates(const std::string &json) {
    std::vector<std::string> result;
    if (json.empty() || json[0] != '[') return result;

    std::string current;
    bool inString = false;
    bool escaped = false;

    for (size_t i = 1; i < json.size(); i++) {
        char c = json[i];
        if (escaped) {
            current += c;
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') {
            if (inString) {
                result.push_back(current);
                current.clear();
                inString = false;
            } else {
                inString = true;
            }
        } else if (inString) {
            current += c;
        }
        if (c == ']') break;
    }
    return result;
}

// ============================================================
// Original function pointers
// ============================================================
typedef void (*insertText_t)(QTextCursor *, const QString &);
static insertText_t originalInsertText = nullptr;

typedef void (*commit_t)(void *);
static commit_t originalCommit = nullptr;

// ============================================================
// Helper: check if IME server is available
// ============================================================
static bool imeServerAvailable() {
    static bool checked = false;
    static bool available = false;
    if (!checked) {
        std::string resp = httpGet(std::string(IME_SERVER) + "/health");
        available = (resp.find("ok") != std::string::npos || resp.size() > 0);
        checked = true;
    }
    return available;
}

// ============================================================
// Commit a Chinese character to the text cursor
// ============================================================
static void commitCharacter(QTextCursor *cursor, const std::string &ch) {
    g_committing = true;
    // We need to call the original insertText with a QString
    // Since we can't construct a QString easily, we'll use a different approach:
    // call the original insertText function directly
    // Actually, we need the QString. Let's use a different approach.
    g_committing = false;
}

// ============================================================
// Hook: QTextCursor::insertText
// ============================================================
extern "C" __attribute__((visibility("default")))
void _ZN11QTextCursor10insertTextERK7QString(QTextCursor *cursor, const QString &text) {
    // Get original function
    if (!originalInsertText) {
        originalInsertText = (insertText_t)dlsym(RTLD_NEXT, "_ZN11QTextCursor10insertTextERK7QString");
        if (!originalInsertText) {
            // Try alternate mangled name
            originalInsertText = (insertText_t)dlsym(RTLD_DEFAULT, "_ZN11QTextCursor10insertTextERK7QString");
        }
    }

    if (!originalInsertText || !g_intercepting || g_committing) {
        if (originalInsertText) {
            originalInsertText(cursor, text);
        }
        return;
    }

    // At this point we'd need to extract the actual char* from QString
    // and route through the pinyin engine.
    // For now, just pass through.
    originalInsertText(cursor, text);
}

// ============================================================
// Alternative: Hook QMetaObject::metacall for QML method calls
// ============================================================
extern "C" __attribute__((visibility("default")))
int qt_metacall_hook(void *object, int call, int id, void **argv) {
    // Get original
    static int (*original)(void *, int, int, void **) = nullptr;
    if (!original) {
        original = (int (*)(void *, int, int, void **))dlsym(RTLD_NEXT, "qt_metacall");
    }

    if (!original || !g_intercepting || g_committing) {
        return original ? original(object, call, id, argv) : 0;
    }

    // Intercept QMetaObject::InvokeMetaMethod
    if (call == 1) { // QMetaObject::InvokeMetaMethod
        // Check if this is the virtual keyboard's insertText method
        // We'd need to identify the object and method by name
    }

    return original(object, call, id, argv);
}

// ============================================================
// Constructor: initialize curl
// ============================================================
__attribute__((constructor))
static void init() {
    curl_global_init(CURL_GLOBAL_ALL);
    fprintf(stderr, "[pinyin-intercept] Loaded! IME server available: %s\n",
            imeServerAvailable() ? "yes" : "no");
}

__attribute__((destructor))
static void cleanup() {
    curl_global_cleanup();
}
