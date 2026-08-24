// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

package store

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/tiiuae/ghaf/logseald/internal/protocol"
)

func TestOfflineQueueSealRetryAndRecovery(t *testing.T) {
	chainBytes := make([]byte, 32)
	for i := range chainBytes {
		chainBytes[i] = byte(255 - i)
	}
	chainID := "spki-sha256:" + hex.EncodeToString(chainBytes)
	producerDir, sealerDir := t.TempDir(), t.TempDir()
	producer, err := OpenProducer(producerDir, chainID, "test-vm")
	if err != nil {
		t.Fatal(err)
	}
	sealer, err := OpenSealer(sealerDir)
	if err != nil {
		t.Fatal(err)
	}
	request1 := enqueueTestBlock(t, producer, "one")
	request2 := enqueueTestBlock(t, producer, "two")
	if producer.QueueDepth() != 2 {
		t.Fatalf("offline queue depth = %d, want 2", producer.QueueDepth())
	}
	response1, err := sealer.Seal(chainID, request1)
	if err != nil {
		t.Fatal(err)
	}
	retry, err := sealer.Seal(chainID, request1)
	if err != nil || retry != response1 {
		t.Fatalf("idempotent retry changed: %#v, %v", retry, err)
	}
	if err := producer.PersistSeal(request1, response1); err != nil {
		t.Fatal(err)
	}
	response2, err := sealer.Seal(chainID, request2)
	if err != nil {
		t.Fatal(err)
	}
	if response2.SealSequence != 2 {
		t.Fatalf("seal sequence = %d, want 2", response2.SealSequence)
	}
	if err := producer.PersistSeal(request2, response2); err != nil {
		t.Fatal(err)
	}

	producer, err = OpenProducer(producerDir, chainID, "test-vm")
	if err != nil {
		t.Fatalf("recover producer: %v", err)
	}
	sealer, err = OpenSealer(sealerDir)
	if err != nil {
		t.Fatalf("recover sealer: %v", err)
	}
	if producer.SealedCount() != 2 || producer.QueueDepth() != 0 || sealer.EntryCount() != 2 {
		t.Fatalf("unexpected recovered state: sealed=%d queued=%d ledger=%d", producer.SealedCount(), producer.QueueDepth(), sealer.EntryCount())
	}

	conflict := request2
	conflict.RequestID = request1.RequestID
	if _, err := sealer.Seal(chainID, conflict); err == nil {
		t.Fatal("conflicting reuse of an idempotency ID was accepted")
	}
	if _, err := sealer.Seal("spki-sha256:"+hex.EncodeToString(make([]byte, 32)), request2); err == nil {
		t.Fatal("request from a different authenticated identity was accepted")
	}
}

func TestPersistedSignatureTamperingIsDetected(t *testing.T) {
	chainID := "spki-sha256:" + hex.EncodeToString(make([]byte, 32))
	producerDir, sealerDir := t.TempDir(), t.TempDir()
	producer, err := OpenProducer(producerDir, chainID, "test-vm")
	if err != nil {
		t.Fatal(err)
	}
	sealer, err := OpenSealer(sealerDir)
	if err != nil {
		t.Fatal(err)
	}
	request := enqueueTestBlock(t, producer, "tamper")
	response, err := sealer.Seal(chainID, request)
	if err != nil {
		t.Fatal(err)
	}
	if err := producer.PersistSeal(request, response); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(producerDir, "sealed", "00000000000000000001.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var entry protocol.LedgerEntry
	if err := json.Unmarshal(data, &entry); err != nil {
		t.Fatal(err)
	}
	if entry.Response.Signature[0] == 'A' {
		entry.Response.Signature = "B" + entry.Response.Signature[1:]
	} else {
		entry.Response.Signature = "A" + entry.Response.Signature[1:]
	}
	data, err = protocol.MarshalJSONLine(entry)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenProducer(producerDir, chainID, "test-vm"); err == nil {
		t.Fatal("producer accepted a modified persisted signature")
	}
}

func enqueueTestBlock(t *testing.T, producer *ProducerStore, cursor string) protocol.SealRequest {
	t.Helper()
	record, err := protocol.EncodeRecord(protocol.Record{Fields: []protocol.Field{
		{Name: "__CURSOR", Value: []byte(cursor)},
		{Name: "_BOOT_ID", Value: []byte("boot")},
		{Name: "MESSAGE", Value: []byte(cursor)},
	}})
	if err != nil {
		t.Fatal(err)
	}
	block := protocol.Block{
		ChainID:          producer.ChainID(),
		SourceName:       producer.SourceName(),
		ProducerSequence: producer.NextSequence(),
		PreviousBlockID:  producer.PreviousBlockID(),
		BootID:           "boot",
		FirstCursor:      cursor,
		LastCursor:       cursor,
		Records:          [][]byte{record},
		MerkleRoot:       protocol.MerkleRoot([][]byte{record}),
	}
	request, err := producer.Enqueue(block)
	if err != nil {
		t.Fatal(err)
	}
	return request
}
