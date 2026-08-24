// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

package store

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"github.com/tiiuae/ghaf/logseald/internal/durable"
	"github.com/tiiuae/ghaf/logseald/internal/protocol"
)

type chainHead struct {
	Sequence uint64
	BlockID  [32]byte
}

type rememberedRequest struct {
	Digest   [32]byte
	Response protocol.SealResponse
}

type SealerStore struct {
	mu         sync.Mutex
	root       string
	publicKey  ed25519.PublicKey
	privateKey ed25519.PrivateKey
	nextSeal   uint64
	heads      map[string]chainHead
	requests   map[string]rememberedRequest
}

func OpenSealer(root string) (*SealerStore, error) {
	if root == "" {
		return nil, fmt.Errorf("sealer state directory is required")
	}
	state := &SealerStore{
		root:     root,
		nextSeal: 1,
		heads:    make(map[string]chainHead),
		requests: make(map[string]rememberedRequest),
	}
	if err := os.MkdirAll(state.ledgerDir(), 0o750); err != nil {
		return nil, fmt.Errorf("create sealer state directory: %w", err)
	}
	if err := state.loadOrCreateKey(); err != nil {
		return nil, err
	}
	if err := state.loadLedger(); err != nil {
		return nil, err
	}
	return state, nil
}

func (state *SealerStore) loadOrCreateKey() error {
	key, err := os.ReadFile(state.keyPath())
	if errors.Is(err, os.ErrNotExist) {
		publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
		if err != nil {
			return fmt.Errorf("generate sealer key: %w", err)
		}
		if err := durable.WriteFile(state.keyPath(), privateKey, 0o600); err != nil {
			return fmt.Errorf("persist sealer key: %w", err)
		}
		state.publicKey, state.privateKey = publicKey, privateKey
		return nil
	}
	if err != nil {
		return fmt.Errorf("read sealer key: %w", err)
	}
	if len(key) != ed25519.PrivateKeySize {
		return fmt.Errorf("invalid sealer private key length")
	}
	state.privateKey = ed25519.PrivateKey(key)
	state.publicKey = append(ed25519.PublicKey(nil), state.privateKey.Public().(ed25519.PublicKey)...)
	return nil
}

func (state *SealerStore) loadLedger() error {
	entries := make(map[uint64]protocol.LedgerEntry)
	if err := forEachArtifact(state.ledgerDir(), func(path string, data []byte) error {
		var entry protocol.LedgerEntry
		if err := decodeStrictJSON(data, &entry); err != nil {
			return fmt.Errorf("decode ledger entry %s: %w", path, err)
		}
		if _, exists := entries[entry.Response.SealSequence]; exists {
			return fmt.Errorf("duplicate seal sequence %d", entry.Response.SealSequence)
		}
		entries[entry.Response.SealSequence] = entry
		return nil
	}); err != nil {
		return err
	}
	sequences := make([]uint64, 0, len(entries))
	for sequence := range entries {
		sequences = append(sequences, sequence)
	}
	sort.Slice(sequences, func(i, j int) bool { return sequences[i] < sequences[j] })
	for index, sequence := range sequences {
		if sequence != uint64(index+1) {
			return fmt.Errorf("ledger is missing seal sequence %d", index+1)
		}
		entry := entries[sequence]
		block, body, err := protocol.DecodeSealRequest(entry.Request)
		if err != nil {
			return fmt.Errorf("validate ledger request %d: %w", sequence, err)
		}
		if _, err := protocol.VerifySealResponse(entry.Request, entry.Response, state.publicKey); err != nil {
			return fmt.Errorf("verify ledger response %d: %w", sequence, err)
		}
		if entry.Response.SealSequence != sequence {
			return fmt.Errorf("ledger response sequence mismatch")
		}
		head := state.heads[block.ChainID]
		if block.ProducerSequence != head.Sequence+1 || block.PreviousBlockID != head.BlockID {
			return fmt.Errorf("ledger chain %s is discontinuous at producer sequence %d", block.ChainID, block.ProducerSequence)
		}
		id := protocol.BlockID(body)
		state.heads[block.ChainID] = chainHead{Sequence: block.ProducerSequence, BlockID: id}
		digest, err := protocol.RequestDigest(entry.Request)
		if err != nil {
			return err
		}
		if _, duplicate := state.requests[entry.Request.RequestID]; duplicate {
			return fmt.Errorf("duplicate request ID in ledger")
		}
		state.requests[entry.Request.RequestID] = rememberedRequest{Digest: digest, Response: entry.Response}
	}
	state.nextSeal = uint64(len(entries)) + 1
	return nil
}

// Seal validates and durably records one request. Identical retries return the
// original response without consuming another global sequence number.
func (state *SealerStore) Seal(peerChainID string, request protocol.SealRequest) (protocol.SealResponse, error) {
	state.mu.Lock()
	defer state.mu.Unlock()

	block, body, err := protocol.DecodeSealRequest(request)
	if err != nil {
		return protocol.SealResponse{}, err
	}
	digest, err := protocol.RequestDigest(request)
	if err != nil {
		return protocol.SealResponse{}, err
	}
	if remembered, found := state.requests[request.RequestID]; found {
		if remembered.Digest != digest || remembered.Response.ChainID != peerChainID {
			return protocol.SealResponse{}, fmt.Errorf("request ID was reused with different content or identity")
		}
		return remembered.Response, nil
	}
	if block.ChainID != peerChainID {
		return protocol.SealResponse{}, fmt.Errorf("block chain ID does not match authenticated client identity")
	}
	head := state.heads[peerChainID]
	if block.ProducerSequence != head.Sequence+1 {
		return protocol.SealResponse{}, fmt.Errorf("expected producer sequence %d, got %d", head.Sequence+1, block.ProducerSequence)
	}
	if block.PreviousBlockID != head.BlockID {
		return protocol.SealResponse{}, fmt.Errorf("producer predecessor does not match sealed chain head")
	}
	response, err := protocol.NewSealResponse(request, block, state.nextSeal, state.publicKey, state.privateKey)
	if err != nil {
		return protocol.SealResponse{}, err
	}
	entry := protocol.LedgerEntry{Request: request, Response: response}
	data, err := protocol.MarshalJSONLine(entry)
	if err != nil {
		return protocol.SealResponse{}, err
	}
	if err := durable.WriteFile(artifactPath(state.ledgerDir(), state.nextSeal), data, 0o640); err != nil {
		return protocol.SealResponse{}, fmt.Errorf("persist sealer ledger entry: %w", err)
	}
	id := protocol.BlockID(body)
	state.heads[peerChainID] = chainHead{Sequence: block.ProducerSequence, BlockID: id}
	state.requests[request.RequestID] = rememberedRequest{Digest: digest, Response: response}
	state.nextSeal++
	return response, nil
}

func (state *SealerStore) PublicKey() ed25519.PublicKey {
	state.mu.Lock()
	defer state.mu.Unlock()
	return append(ed25519.PublicKey(nil), state.publicKey...)
}

func (state *SealerStore) LedgerDirectory() string { return state.ledgerDir() }
func (state *SealerStore) EntryCount() uint64 {
	state.mu.Lock()
	defer state.mu.Unlock()
	return state.nextSeal - 1
}
func (state *SealerStore) ledgerDir() string { return filepath.Join(state.root, "ledger") }
func (state *SealerStore) keyPath() string   { return filepath.Join(state.root, "sealer.key") }
