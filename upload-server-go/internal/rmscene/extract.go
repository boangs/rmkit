// Package rmscene parses reMarkable v6 .rm files and extracts typed text.
//
// Ported from https://github.com/ricklupton/rmscene (text extraction subset).
// We only implement what's needed to pull plain text out of RootTextBlock —
// strokes, scene tree, and other block types are skipped.
package rmscene

import (
	"fmt"
	"io"
	"os"
)

// ExtractText reads a v6 .rm file from rd and returns the typed text content.
// Returns "" with nil error if the file has no text block.
func ExtractText(rd io.Reader) (string, error) {
	data, err := io.ReadAll(rd)
	if err != nil {
		return "", fmt.Errorf("rmscene: read: %w", err)
	}
	return ExtractTextBytes(data)
}

// ExtractTextBytes is like ExtractText but takes raw bytes.
func ExtractTextBytes(data []byte) (string, error) {
	rt, err := readFirstRootText(data)
	if err != nil {
		return "", fmt.Errorf("rmscene: parse: %w", err)
	}
	if rt == nil {
		return "", nil
	}
	return extractPlainText(rt.Value), nil
}

// ExtractTextFile is a convenience wrapper around ExtractText for a file path.
func ExtractTextFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	return ExtractText(f)
}
