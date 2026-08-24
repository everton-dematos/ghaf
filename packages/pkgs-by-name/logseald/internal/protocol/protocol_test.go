// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

package protocol

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"testing"
)

func TestRecordCanonicalizationPreservesBinaryDuplicates(t *testing.T) {
	record := Record{Fields: []Field{
		{Name: "MESSAGE", Value: []byte{'z', 0, 'x'}},
		{Name: "A", Value: []byte("second")},
		{Name: "A", Value: []byte("first")},
	}}
	encoded, err := EncodeRecord(record)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeRecord(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded.Fields) != 3 || decoded.Fields[0].Name != "A" || string(decoded.Fields[0].Value) != "first" || !bytes.Equal(decoded.Fields[2].Value, []byte{'z', 0, 'x'}) {
		t.Fatalf("unexpected canonical fields: %#v", decoded.Fields)
	}
	encoded = append(encoded, 0)
	if _, err := DecodeRecord(encoded); err == nil {
		t.Fatal("modified canonical record was accepted")
	}
}

func TestBlockAndSealBindAllSecurityFields(t *testing.T) {
	record, err := EncodeRecord(Record{Fields: []Field{{Name: "MESSAGE", Value: []byte("hello")}}})
	if err != nil {
		t.Fatal(err)
	}
	chainHash := make([]byte, 32)
	for i := range chainHash {
		chainHash[i] = byte(i)
	}
	block := Block{
		ChainID:          "spki-sha256:" + hex.EncodeToString(chainHash),
		SourceName:       "test-vm",
		ProducerSequence: 1,
		BootID:           "boot-one",
		FirstCursor:      "cursor-one",
		LastCursor:       "cursor-one",
		Records:          [][]byte{record},
		MerkleRoot:       MerkleRoot([][]byte{record}),
	}
	body, err := EncodeBlock(block)
	if err != nil {
		t.Fatal(err)
	}
	request, decoded, err := NewSealRequest("00000000000000000000000000000001", body)
	if err != nil {
		t.Fatal(err)
	}
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	response, err := NewSealResponse(request, decoded, 1, publicKey, privateKey)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := VerifySealResponse(request, response, nil); err != nil {
		t.Fatal(err)
	}
	response.RequestID = "00000000000000000000000000000002"
	request.RequestID = response.RequestID
	if _, err := VerifySealResponse(request, response, nil); err == nil {
		t.Fatal("signature was not bound to the request ID")
	}

	block.MerkleRoot[0] ^= 1
	if _, err := EncodeBlock(block); err == nil {
		t.Fatal("block with altered Merkle root was accepted")
	}
}
