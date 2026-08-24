// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

package journal

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestReadTextAndBinaryJournalFields(t *testing.T) {
	var export bytes.Buffer
	export.WriteString("__CURSOR=cursor-1\n_BOOT_ID=boot-1\nMESSAGE\n")
	if err := binary.Write(&export, binary.LittleEndian, uint64(5)); err != nil {
		t.Fatal(err)
	}
	export.Write([]byte{'a', 0, 'b', '\n', 'c'})
	export.WriteString("\n\n")
	record, err := NewReader(&export).ReadRecord()
	if err != nil {
		t.Fatal(err)
	}
	if len(record.Fields) != 3 || !bytes.Equal(record.Fields[2].Value, []byte{'a', 0, 'b', '\n', 'c'}) {
		t.Fatalf("binary field was not preserved: %#v", record.Fields)
	}
}

func TestRejectTruncatedBinaryJournalField(t *testing.T) {
	var export bytes.Buffer
	export.WriteString("MESSAGE\n")
	if err := binary.Write(&export, binary.LittleEndian, uint64(8)); err != nil {
		t.Fatal(err)
	}
	export.WriteString("short")
	if _, err := NewReader(&export).ReadRecord(); err == nil {
		t.Fatal("truncated binary field was accepted")
	}
}
