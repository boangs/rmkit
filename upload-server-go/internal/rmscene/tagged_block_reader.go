package rmscene

import (
	"errors"
	"fmt"
	"io"
)

type mainBlockInfo struct {
	offset         int64
	size           uint32
	blockType      uint8
	minVersion     uint8
	currentVersion uint8
}

type subBlockInfo struct {
	offset int64
	size   uint32
}

type taggedBlockReader struct {
	data         *dataStream
	currentBlock *mainBlockInfo
}

func newTaggedBlockReader(data []byte) *taggedBlockReader {
	return &taggedBlockReader{data: newDataStream(data)}
}

func (r *taggedBlockReader) readHeader() error { return r.data.readHeader() }

func (r *taggedBlockReader) readID(idx uint64) (CrdtID, error) {
	if err := r.data.readTag(idx, tagID); err != nil {
		return CrdtID{}, err
	}
	return r.data.readCrdtID()
}

func (r *taggedBlockReader) readBool(idx uint64) (bool, error) {
	if err := r.data.readTag(idx, tagByte1); err != nil {
		return false, err
	}
	return r.data.readBool()
}

func (r *taggedBlockReader) readByte(idx uint64) (uint8, error) {
	if err := r.data.readTag(idx, tagByte1); err != nil {
		return 0, err
	}
	return r.data.readUint8()
}

func (r *taggedBlockReader) readInt(idx uint64) (uint32, error) {
	if err := r.data.readTag(idx, tagByte4); err != nil {
		return 0, err
	}
	return r.data.readUint32()
}

func (r *taggedBlockReader) readFloat(idx uint64) (float32, error) {
	if err := r.data.readTag(idx, tagByte4); err != nil {
		return 0, err
	}
	return r.data.readFloat32()
}

func (r *taggedBlockReader) readDouble(idx uint64) (float64, error) {
	if err := r.data.readTag(idx, tagByte8); err != nil {
		return 0, err
	}
	return r.data.readFloat64()
}

// readBlock returns nil with io.EOF when no more blocks.
func (r *taggedBlockReader) readBlock() (*mainBlockInfo, error) {
	if r.currentBlock != nil {
		return nil, fmt.Errorf("already in a block")
	}
	blockLen, err := r.data.readUint32()
	if err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return nil, io.EOF
		}
		return nil, err
	}
	unknown, err := r.data.readUint8()
	if err != nil {
		return nil, err
	}
	if unknown != 0 {
		return nil, fmt.Errorf("unexpected unknown header byte = %d", unknown)
	}
	minVer, err := r.data.readUint8()
	if err != nil {
		return nil, err
	}
	curVer, err := r.data.readUint8()
	if err != nil {
		return nil, err
	}
	bt, err := r.data.readUint8()
	if err != nil {
		return nil, err
	}
	info := &mainBlockInfo{
		offset:         r.data.tell(),
		size:           blockLen,
		blockType:      bt,
		minVersion:     minVer,
		currentVersion: curVer,
	}
	r.currentBlock = info
	return info, nil
}

func (r *taggedBlockReader) endBlock() error {
	if r.currentBlock == nil {
		return fmt.Errorf("not in a block")
	}
	end := r.currentBlock.offset + int64(r.currentBlock.size)
	cur := r.data.tell()
	if cur > end {
		r.currentBlock = nil
		return fmt.Errorf("%w: read %d past block end", errBlockOverflow, cur-end)
	}
	if cur < end {
		if err := r.data.seek(end); err != nil {
			return err
		}
	}
	r.currentBlock = nil
	return nil
}

func (r *taggedBlockReader) bytesRemainingInBlock() int64 {
	if r.currentBlock == nil {
		return 0
	}
	return r.currentBlock.offset + int64(r.currentBlock.size) - r.data.tell()
}

func (r *taggedBlockReader) readSubblock(idx uint64) (*subBlockInfo, error) {
	if err := r.data.readTag(idx, tagLength4); err != nil {
		return nil, err
	}
	sz, err := r.data.readUint32()
	if err != nil {
		return nil, err
	}
	return &subBlockInfo{offset: r.data.tell(), size: sz}, nil
}

func (r *taggedBlockReader) endSubblock(sb *subBlockInfo) error {
	end := sb.offset + int64(sb.size)
	cur := r.data.tell()
	if cur > end {
		return fmt.Errorf("%w: subblock overflow %d", errBlockOverflow, cur-end)
	}
	if cur < end {
		if err := r.data.seek(end); err != nil {
			return err
		}
	}
	return nil
}

func (r *taggedBlockReader) hasSubblock(idx uint64) bool {
	if r.currentBlock != nil && r.bytesRemainingInBlock() <= 0 {
		return false
	}
	return r.data.checkTag(idx, tagLength4)
}

func (r *taggedBlockReader) readString(idx uint64) (string, error) {
	sb, err := r.readSubblock(idx)
	if err != nil {
		return "", err
	}
	strLen, err := r.data.readVaruint()
	if err != nil {
		return "", err
	}
	if _, err := r.data.readBool(); err != nil {
		return "", err
	}
	b, err := r.data.readBytes(int(strLen))
	if err != nil {
		return "", err
	}
	if err := r.endSubblock(sb); err != nil {
		return "", err
	}
	return string(b), nil
}

// readStringWithFormat reads UTF-8 string + optional uint32 format code.
func (r *taggedBlockReader) readStringWithFormat(idx uint64) (string, *uint32, error) {
	sb, err := r.readSubblock(idx)
	if err != nil {
		return "", nil, err
	}
	strLen, err := r.data.readVaruint()
	if err != nil {
		return "", nil, err
	}
	if _, err := r.data.readBool(); err != nil {
		return "", nil, err
	}
	b, err := r.data.readBytes(int(strLen))
	if err != nil {
		return "", nil, err
	}
	var fmtCode *uint32
	if r.data.checkTag(2, tagByte4) {
		v, err := r.readInt(2)
		if err != nil {
			return "", nil, err
		}
		fmtCode = &v
	}
	if err := r.endSubblock(sb); err != nil {
		return "", nil, err
	}
	return string(b), fmtCode, nil
}
