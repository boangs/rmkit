package rmscene

import (
	"fmt"
	"io"
)

const blockTypeRootText = 0x07

// TextItem represents one CRDT text node. Value is either string or uint32 (format code).
type TextItem struct {
	ItemID        CrdtID
	LeftID        CrdtID
	RightID       CrdtID
	DeletedLength uint32
	Value         any
}

type ParagraphStyle uint8

const (
	StyleBasic           ParagraphStyle = 0
	StylePlain           ParagraphStyle = 1
	StyleHeading         ParagraphStyle = 2
	StyleBold            ParagraphStyle = 3
	StyleBullet          ParagraphStyle = 4
	StyleBullet2         ParagraphStyle = 5
	StyleCheckbox        ParagraphStyle = 6
	StyleCheckboxChecked ParagraphStyle = 7
)

type TextStyle struct {
	Timestamp CrdtID
	Style     ParagraphStyle
}

type Text struct {
	Items  []TextItem
	Styles map[CrdtID]TextStyle
	PosX   float64
	PosY   float64
	Width  float32
}

type RootTextBlock struct {
	BlockID CrdtID
	Value   Text
}

// readFirstRootText scans blocks and returns the first RootTextBlock found,
// or nil if none. Other block types are skipped.
func readFirstRootText(data []byte) (*RootTextBlock, error) {
	r := newTaggedBlockReader(data)
	if err := r.readHeader(); err != nil {
		return nil, err
	}
	for {
		info, err := r.readBlock()
		if err == io.EOF {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		if info.blockType == blockTypeRootText {
			rt, err := readRootTextBlock(r)
			if err != nil {
				return nil, err
			}
			if err := r.endBlock(); err != nil {
				return nil, err
			}
			return rt, nil
		}
		if err := r.endBlock(); err != nil {
			return nil, err
		}
	}
}

func readRootTextBlock(r *taggedBlockReader) (*RootTextBlock, error) {
	blockID, err := r.readID(1)
	if err != nil {
		return nil, fmt.Errorf("read block_id: %w", err)
	}

	var (
		items      []TextItem
		styles     map[CrdtID]TextStyle
		posX, posY float64
		width      float32
	)

	sb2, err := r.readSubblock(2)
	if err != nil {
		return nil, err
	}

	// Items
	sb21, err := r.readSubblock(1)
	if err != nil {
		return nil, err
	}
	sb211, err := r.readSubblock(1)
	if err != nil {
		return nil, err
	}
	n, err := r.data.readVaruint()
	if err != nil {
		return nil, err
	}
	items = make([]TextItem, 0, n)
	for i := uint64(0); i < n; i++ {
		ti, err := readTextItem(r)
		if err != nil {
			return nil, fmt.Errorf("text item %d: %w", i, err)
		}
		items = append(items, ti)
	}
	if err := r.endSubblock(sb211); err != nil {
		return nil, err
	}
	if err := r.endSubblock(sb21); err != nil {
		return nil, err
	}

	// Styles
	sb22, err := r.readSubblock(2)
	if err != nil {
		return nil, err
	}
	sb221, err := r.readSubblock(1)
	if err != nil {
		return nil, err
	}
	nf, err := r.data.readVaruint()
	if err != nil {
		return nil, err
	}
	styles = make(map[CrdtID]TextStyle, nf)
	for i := uint64(0); i < nf; i++ {
		cid, ts, err := readTextFormat(r)
		if err != nil {
			return nil, fmt.Errorf("text format %d: %w", i, err)
		}
		styles[cid] = ts
	}
	if err := r.endSubblock(sb221); err != nil {
		return nil, err
	}
	if err := r.endSubblock(sb22); err != nil {
		return nil, err
	}
	if err := r.endSubblock(sb2); err != nil {
		return nil, err
	}

	sb3, err := r.readSubblock(3)
	if err != nil {
		return nil, err
	}
	posX, err = r.data.readFloat64()
	if err != nil {
		return nil, err
	}
	posY, err = r.data.readFloat64()
	if err != nil {
		return nil, err
	}
	if err := r.endSubblock(sb3); err != nil {
		return nil, err
	}

	width, err = r.readFloat(4)
	if err != nil {
		return nil, err
	}

	return &RootTextBlock{
		BlockID: blockID,
		Value: Text{
			Items:  items,
			Styles: styles,
			PosX:   posX,
			PosY:   posY,
			Width:  width,
		},
	}, nil
}

func readTextItem(r *taggedBlockReader) (TextItem, error) {
	sb, err := r.readSubblock(0)
	if err != nil {
		return TextItem{}, err
	}
	itemID, err := r.readID(2)
	if err != nil {
		return TextItem{}, err
	}
	leftID, err := r.readID(3)
	if err != nil {
		return TextItem{}, err
	}
	rightID, err := r.readID(4)
	if err != nil {
		return TextItem{}, err
	}
	delLen, err := r.readInt(5)
	if err != nil {
		return TextItem{}, err
	}
	var value any = ""
	if r.hasSubblock(6) {
		s, fc, err := r.readStringWithFormat(6)
		if err != nil {
			return TextItem{}, err
		}
		if fc != nil {
			value = *fc
		} else {
			value = s
		}
	}
	if err := r.endSubblock(sb); err != nil {
		return TextItem{}, err
	}
	return TextItem{itemID, leftID, rightID, delLen, value}, nil
}

func readTextFormat(r *taggedBlockReader) (CrdtID, TextStyle, error) {
	cid, err := r.data.readCrdtID()
	if err != nil {
		return CrdtID{}, TextStyle{}, err
	}
	ts, err := r.readID(1)
	if err != nil {
		return CrdtID{}, TextStyle{}, err
	}
	sb, err := r.readSubblock(2)
	if err != nil {
		return CrdtID{}, TextStyle{}, err
	}
	c, err := r.data.readUint8()
	if err != nil {
		return CrdtID{}, TextStyle{}, err
	}
	if c != 17 {
		return CrdtID{}, TextStyle{}, fmt.Errorf("expected magic 17, got %d", c)
	}
	code, err := r.data.readUint8()
	if err != nil {
		return CrdtID{}, TextStyle{}, err
	}
	if err := r.endSubblock(sb); err != nil {
		return CrdtID{}, TextStyle{}, err
	}
	style := ParagraphStyle(code)
	if style > StyleCheckboxChecked {
		style = StylePlain
	}
	return cid, TextStyle{Timestamp: ts, Style: style}, nil
}
