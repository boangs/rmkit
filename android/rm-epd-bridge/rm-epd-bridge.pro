QT += core gui svg
CONFIG += console c++17
CONFIG -= app_bundle

TARGET = rm-epd-bridge
SOURCES += rm-epd-bridge.cpp

INCLUDEPATH += $$PWD/third_party/oxide

# lib58/ 放从 3.28 设备取回的 /usr/lib/plugins/scenegraph/libqsgepaper.so (Qt 6.10);
# SDK sysroot 是 3.27 (Qt 6.8), 新库自身缺的 Qt 符号运行时由设备提供
LIBS += -L$$PWD/lib58 -L$$[QT_SYSROOT]/usr/lib/plugins/scenegraph -lqsgepaper -ldl
QMAKE_RPATHDIR += /usr/lib/plugins/scenegraph
QMAKE_LFLAGS += -Wl,--allow-shlib-undefined
