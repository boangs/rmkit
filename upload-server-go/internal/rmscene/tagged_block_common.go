package rmscene

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

var headerV6 = []byte("reMarkable .lines file, version=6          ")

type tagType uint8

const (
	tagID      tagType = 0xF
	tagLength4 tagType = 0xC
	tagByte8   tagType = 0x8
	tagByte4   tagType = 0x4
	tagByte1   tagType = 0x1
)

type CrdtID struct {
	Part1 uint8
	Part2 uint64
}

func (c CrdtID) String() string { return fmt.Sprintf("CrdtId(%d,%d)", c.Part1, c.Part2) }

var endMarker = CrdtID{0, 0}

var (
	errUnexpectedBlock = errors.New("unexpected block")
	errBlockOverflow   = errors.New("block overflow")
)

type dataStream struct{ r *bytes.Reader }

func newDataStream(data []byte) *dataStream { return &dataStream{r: bytes.NewReader(data)} }

func (s *dataStream) tell() int64 { return s.r.Size() - int64(s.r.Len()) }

func (s *dataStream) seek(off int64) error {
	_, err := s.r.Seek(off, io.SeekStart)
	return err
}

func (s *dataStream) readHeader() error {
	buf := make([]byte, len(headerV6))
	if _, err := io.ReadFull(s.r, buf); err != nil {
		return fmt.Errorf("read header: %w", err)
	}
	if !bytes.Equal(buf, headerV6) {
		return fmt.Errorf("wrong header: %q", buf)
	}
	return nil
}

func (s *dataStream) readBytes(n int) ([]byte, error) {
	buf := make([]byte, n)
	_, err := io.ReadFull(s.r, buf)
	return buf, err
}

func (s *dataStream) readUint8() (uint8, error) { return s.r.ReadByte() }
func (s *dataStream) readBool() (bool, error)   { b, err := s.r.ReadByte(); return b != 0, err }
func (s *dataStream) readUint16() (v uint16, err error) {
	err = binary.Read(s.r, binary.LittleEndian, &v)
	return
}
func (s *dataStream) readUint32() (v uint32, err error) {
	err = binary.Read(s.r, binary.LittleEndian, &v)
	return
}
func (s *dataStream) readFloat32() (v float32, err error) {
	err = binary.Read(s.r, binary.LittleEndian, &v)
	return
}
func (s *dataStream) readFloat64() (v float64, err error) {
	err = binary.Read(s.r, binary.LittleEndian, &v)
	return
}

func (s *dataStream) readVaruint() (uint64, error) {
	var result uint64
	var shift uint
	for {
		b, err := s.r.ReadByte()
		if err != nil {
			return 0, err
		}
		result |= uint64(b&0x7F) << shift
		shift += 7
		if b&0x80 == 0 {
			break
		}
		if shift >= 64 {
			return 0, fmt.Errorf("varuint too long")
		}
	}
	return result, nil
}

func (s *dataStream) readCrdtID() (CrdtID, error) {
	p1, err := s.readUint8()
	if err != nil {
		return CrdtID{}, err
	}
	p2, err := s.readVaruint()
	if err != nil {
		return CrdtID{}, err
	}
	return CrdtID{p1, p2}, nil
}

func (s *dataStream) readTagValues() (uint64, tagType, error) {
	x, err := s.readVaruint()
	if err != nil {
		return 0, 0, err
	}
	idx := x >> 4
	tt := tagType(x & 0xF)
	switch tt {
	case tagID, tagLength4, tagByte8, tagByte4, tagByte1:
		return idx, tt, nil
	default:
		return 0, 0, fmt.Errorf("bad tag type 0x%X at offset %d", uint8(tt), s.tell())
	}
}

func (s *dataStream) checkTag(expectedIdx uint64, expectedType tagType) bool {
	pos := s.tell()
	idx, tt, err := s.readTagValues()
	_ = s.seek(pos)
	if err != nil {
		return false
	}
	return idx == expectedIdx && tt == expectedType
}

func (s *dataStream) readTag(expectedIdx uint64, expectedType tagType) error {
	pos := s.tell()
	idx, tt, err := s.readTagValues()
	if err != nil {
		_ = s.seek(pos)
		return err
	}
	if idx != expectedIdx {
		_ = s.seek(pos)
		return fmt.Errorf("%w: expected index %d, got %d at offset %d", errUnexpectedBlock, expectedIdx, idx, pos)
	}
	if tt != expectedType {
		_ = s.seek(pos)
		return fmt.Errorf("%w: expected tag 0x%X, got 0x%X at offset %d", errUnexpectedBlock, expectedType, tt, pos)
	}
	return nil
}
