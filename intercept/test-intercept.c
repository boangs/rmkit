// Minimal test: hook QTextCursor::insertText to verify the approach works
// Build on device: gcc -shared -fPIC -o libtest-intercept.so test-intercept.c -ldl

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

// The mangled name for QTextCursor::insertText(QString const&)
// Qt6 on aarch64 uses the Itanium C++ ABI

typedef void insertText_fn(void *, const void *);
static insertText_fn *real_insertText = 0;

// We can't work with QString directly, so we'll just log the call
// and use a workaround to extract the string data

// Alternative: hook via the Qt library function directly
typedef int (*QString_toUtf8_fn)(const void *, char *, int);
static QString_toUtf8_fn real_toUtf8 = 0;

__attribute__((visibility("default")))
void _ZN11QTextCursor10insertTextERK7QString(void *cursor, const void *qstring) {
    if (!real_insertText) {
        real_insertText = (insertText_fn *)dlsym(RTLD_NEXT, "_ZN11QTextCursor10insertTextERK7QString");
    }
    if (!real_toUtf8) {
        real_toUtf8 = (QString_toUtf8_fn)dlsym(RTLD_NEXT, "_ZNK7QString8toUtf8Ev");
    }

    // Try to get the string content
    // QString::toUtf8() returns a QByteArray - we can't easily extract from it
    // So let's just note that the call happened
    fprintf(stderr, "[intercept-test] QTextCursor::insertText called! cursor=%p qstring=%p\n",
            cursor, qstring);

    if (real_insertText) {
        real_insertText(cursor, qstring);
    }
}

__attribute__((constructor))
static void init(void) {
    fprintf(stderr, "[intercept-test] Library loaded!\n");
    real_insertText = (insertText_fn *)dlsym(RTLD_NEXT, "_ZN11QTextCursor10insertTextERK7QString");
    fprintf(stderr, "[intercept-test] Original insertText at: %p\n", real_insertText);
}
