// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

// Package journal parses the binary-safe Journal Export Format emitted by
// journalctl --output=export.
package journal

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/tiiuae/ghaf/logseald/internal/protocol"
)

// Reader reads one complete journal entry at a time.
type Reader struct {
	input *bufio.Reader
}

func NewReader(input io.Reader) *Reader {
	return &Reader{input: bufio.NewReaderSize(input, 128<<10)}
}

func (reader *Reader) ReadRecord() (protocol.Record, error) {
	record := protocol.Record{}
	for {
		lineBytes, err := reader.readLine()
		if err != nil {
			if errors.Is(err, io.EOF) && len(record.Fields) == 0 {
				return protocol.Record{}, io.EOF
			}
			return protocol.Record{}, fmt.Errorf("read journal export line: %w", err)
		}
		line := string(lineBytes)
		if line == "" {
			if len(record.Fields) == 0 {
				continue
			}
			return record, nil
		}

		name, value, found := strings.Cut(line, "=")
		if found {
			if err := protocol.ValidateFieldName(name); err != nil {
				return protocol.Record{}, err
			}
			if len(value) > protocol.MaxFieldValueBytes {
				return protocol.Record{}, fmt.Errorf("journal field %q is too large", name)
			}
			record.Fields = append(record.Fields, protocol.Field{Name: name, Value: []byte(value)})
		} else {
			if err := protocol.ValidateFieldName(name); err != nil {
				return protocol.Record{}, err
			}
			var length uint64
			if err := binary.Read(reader.input, binary.LittleEndian, &length); err != nil {
				return protocol.Record{}, fmt.Errorf("read binary field %q length: %w", name, err)
			}
			if length > protocol.MaxFieldValueBytes {
				return protocol.Record{}, fmt.Errorf("journal binary field %q is too large", name)
			}
			data := make([]byte, int(length))
			if _, err := io.ReadFull(reader.input, data); err != nil {
				return protocol.Record{}, fmt.Errorf("read binary field %q: %w", name, err)
			}
			terminator, err := reader.input.ReadByte()
			if err != nil || terminator != '\n' {
				return protocol.Record{}, fmt.Errorf("binary field %q has no newline terminator", name)
			}
			record.Fields = append(record.Fields, protocol.Field{Name: name, Value: data})
		}
		if len(record.Fields) > protocol.MaxFieldsPerRecord {
			return protocol.Record{}, fmt.Errorf("journal record has too many fields")
		}
	}
}

func (reader *Reader) readLine() ([]byte, error) {
	const maxLineBytes = protocol.MaxFieldNameBytes + 1 + protocol.MaxFieldValueBytes
	var line []byte
	for {
		fragment, err := reader.input.ReadSlice('\n')
		if len(line)+len(fragment) > maxLineBytes+1 {
			return nil, fmt.Errorf("journal export line is too large")
		}
		line = append(line, fragment...)
		if err == nil {
			return line[:len(line)-1], nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}
