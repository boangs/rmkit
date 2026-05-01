package rmscene

import "strings"

const zwsp = "\u200b"

// expandTextItems splits string-valued TextItems into single-rune items so each
// codepoint has an explicit CrdtID. Format-code items pass through.
// Deleted items are expanded into deleted_length single-rune placeholders with empty value.
func expandTextItems(items []TextItem) []TextItem {
	var out []TextItem
	for _, it := range items {
		if it.DeletedLength > 0 {
			n := it.DeletedLength
			itemID := it.ItemID
			leftID := it.LeftID
			for i := uint32(0); i < n; i++ {
				var rightID CrdtID
				if i == n-1 {
					rightID = it.RightID
				} else {
					rightID = CrdtID{itemID.Part1, itemID.Part2 + 1}
				}
				out = append(out, TextItem{itemID, leftID, rightID, 1, ""})
				leftID = itemID
				itemID = rightID
			}
			continue
		}
		switch v := it.Value.(type) {
		case uint32:
			out = append(out, it)
		case string:
			if v == "" {
				continue
			}
			runes := []rune(v)
			itemID := it.ItemID
			leftID := it.LeftID
			for i, c := range runes {
				var rightID CrdtID
				if i == len(runes)-1 {
					rightID = it.RightID
				} else {
					rightID = CrdtID{itemID.Part1, itemID.Part2 + 1}
				}
				out = append(out, TextItem{itemID, leftID, rightID, 0, string(c)})
				leftID = itemID
				itemID = rightID
			}
		}
	}
	return out
}

// extractPlainText concatenates char-level text items in CRDT order, dropping
// deletion tombstones, format codes, and ZWSP markers (left over from the
// rmkit-cn IME backspace hack).
func extractPlainText(t Text) string {
	expanded := expandTextItems(t.Items)
	if len(expanded) == 0 {
		return ""
	}
	byID := make(map[CrdtID]TextItem, len(expanded))
	for _, it := range expanded {
		byID[it.ItemID] = it
	}
	order := toposort(expanded)
	var b strings.Builder
	for _, id := range order {
		it := byID[id]
		if it.DeletedLength > 0 {
			continue
		}
		s, ok := it.Value.(string)
		if !ok {
			continue
		}
		if s == zwsp {
			continue
		}
		b.WriteString(s)
	}
	return b.String()
}
