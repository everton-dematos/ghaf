// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

package store

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/tiiuae/ghaf/logseald/internal/durable"
	"github.com/tiiuae/ghaf/logseald/internal/protocol"
)

type queuedArtifact struct {
	Request protocol.SealRequest `json:"request"`
}

type ProducerStore struct {
	root                        string
	chainID                     string
	sourceName                  string
	artifacts                   map[uint64]protocol.LedgerEntry
	queued                      map[uint64]protocol.SealRequest
	pinnedKey                   ed25519.PublicKey
	lastBlock                   protocol.Block
	lastID                      [32]byte
	lastCursor                  string
	requireAuthenticatedBinding bool
}

func OpenProducer(root, chainID, sourceName string) (*ProducerStore, error) {
	if root == "" || chainID == "" || sourceName == "" {
		return nil, fmt.Errorf("producer state directory, chain ID and source name are required")
	}
	state := &ProducerStore{
		root:       root,
		chainID:    chainID,
		sourceName: sourceName,
		artifacts:  make(map[uint64]protocol.LedgerEntry),
		queued:     make(map[uint64]protocol.SealRequest),
	}
	for _, dir := range []string{state.queueDir(), state.sealedDir()} {
		if err := os.MkdirAll(dir, 0o750); err != nil {
			return nil, fmt.Errorf("create producer state directory: %w", err)
		}
	}
	key, err := os.ReadFile(state.pinPath())
	if err == nil {
		if len(key) != ed25519.PublicKeySize {
			return nil, fmt.Errorf("invalid pinned sealer key length")
		}
		state.pinnedKey = ed25519.PublicKey(key)
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, fmt.Errorf("read pinned sealer key: %w", err)
	}
	if err := state.loadSealed(); err != nil {
		return nil, err
	}
	if err := state.loadQueue(); err != nil {
		return nil, err
	}
	if err := state.validateHistory(); err != nil {
		return nil, err
	}
	return state, nil
}

func (state *ProducerStore) loadSealed() error {
	return forEachArtifact(state.sealedDir(), func(path string, data []byte) error {
		var entry protocol.LedgerEntry
		if err := decodeStrictJSON(data, &entry); err != nil {
			return fmt.Errorf("decode sealed artifact %s: %w", path, err)
		}
		block, _, err := protocol.DecodeSealRequest(entry.Request)
		if err != nil {
			return fmt.Errorf("validate sealed artifact %s: %w", path, err)
		}
		if state.pinnedKey == nil {
			return fmt.Errorf("sealed artifacts exist without a pinned sealer key")
		}
		if _, err := protocol.VerifySealResponse(entry.Request, entry.Response, state.pinnedKey); err != nil {
			return fmt.Errorf("verify sealed artifact %s: %w", path, err)
		}
		if _, exists := state.artifacts[block.ProducerSequence]; exists {
			return fmt.Errorf("duplicate producer sequence %d", block.ProducerSequence)
		}
		state.artifacts[block.ProducerSequence] = entry
		return nil
	})
}

func (state *ProducerStore) loadQueue() error {
	return forEachArtifact(state.queueDir(), func(path string, data []byte) error {
		var artifact queuedArtifact
		if err := decodeStrictJSON(data, &artifact); err != nil {
			return fmt.Errorf("decode queued artifact %s: %w", path, err)
		}
		block, _, err := protocol.DecodeSealRequest(artifact.Request)
		if err != nil {
			return fmt.Errorf("validate queued artifact %s: %w", path, err)
		}
		if _, sealed := state.artifacts[block.ProducerSequence]; sealed {
			// A crash after writing the sealed artifact but before removing the
			// queue entry is recoverable if both requests are identical.
			if state.artifacts[block.ProducerSequence].Request != artifact.Request {
				return fmt.Errorf("queued and sealed artifacts conflict at sequence %d", block.ProducerSequence)
			}
			return nil
		}
		if _, exists := state.queued[block.ProducerSequence]; exists {
			return fmt.Errorf("duplicate queued producer sequence %d", block.ProducerSequence)
		}
		state.queued[block.ProducerSequence] = artifact.Request
		return nil
	})
}

func (state *ProducerStore) validateHistory() error {
	count := len(state.artifacts) + len(state.queued)
	var previous [32]byte
	for sequence := uint64(1); sequence <= uint64(count); sequence++ {
		request, found := state.queued[sequence]
		if entry, sealed := state.artifacts[sequence]; sealed {
			request, found = entry.Request, true
		}
		if !found {
			return fmt.Errorf("producer history is missing sequence %d", sequence)
		}
		block, body, err := protocol.DecodeSealRequest(request)
		if err != nil {
			return err
		}
		if block.ChainID != state.chainID || block.SourceName != state.sourceName {
			return fmt.Errorf("producer identity changed at sequence %d", sequence)
		}
		if block.PreviousBlockID != previous {
			return fmt.Errorf("producer predecessor mismatch at sequence %d", sequence)
		}
		previous = protocol.BlockID(body)
		state.lastBlock = block
		state.lastID = previous
		state.lastCursor = block.LastCursor
	}
	return nil
}

func (state *ProducerStore) NextSequence() uint64 {
	return uint64(len(state.artifacts)+len(state.queued)) + 1
}

func (state *ProducerStore) PreviousBlockID() [32]byte { return state.lastID }
func (state *ProducerStore) LastCursor() string        { return state.lastCursor }
func (state *ProducerStore) ChainID() string           { return state.chainID }
func (state *ProducerStore) SourceName() string        { return state.sourceName }
func (state *ProducerStore) PinnedKey() ed25519.PublicKey {
	return append(ed25519.PublicKey(nil), state.pinnedKey...)
}

// RequireAuthenticatedKeyBinding disables response-only key bootstrapping.
// The producer runtime enables this before it submits any queued block.
func (state *ProducerStore) RequireAuthenticatedKeyBinding() {
	state.requireAuthenticatedBinding = true
}

// TrustSealerKey persists a key only after the caller has verified its binding
// to the authenticated GIVC server certificate.
func (state *ProducerStore) TrustSealerKey(key ed25519.PublicKey) error {
	if len(key) != ed25519.PublicKeySize {
		return fmt.Errorf("invalid authenticated sealer public key")
	}
	if state.pinnedKey != nil {
		if !bytes.Equal(state.pinnedKey, key) {
			return fmt.Errorf("authenticated sealer public key changed")
		}
		return nil
	}
	if err := durable.WriteFile(state.pinPath(), key, 0o640); err != nil {
		return fmt.Errorf("pin authenticated sealer public key: %w", err)
	}
	state.pinnedKey = append(ed25519.PublicKey(nil), key...)
	return nil
}

func (state *ProducerStore) QueueDepth() int  { return len(state.queued) }
func (state *ProducerStore) SealedCount() int { return len(state.artifacts) }

func (state *ProducerStore) Pending() []protocol.SealRequest {
	sequences := make([]uint64, 0, len(state.queued))
	for sequence := range state.queued {
		sequences = append(sequences, sequence)
	}
	sort.Slice(sequences, func(i, j int) bool { return sequences[i] < sequences[j] })
	requests := make([]protocol.SealRequest, 0, len(sequences))
	for _, sequence := range sequences {
		requests = append(requests, state.queued[sequence])
	}
	return requests
}

func (state *ProducerStore) Enqueue(block protocol.Block) (protocol.SealRequest, error) {
	if block.ChainID != state.chainID || block.SourceName != state.sourceName || block.ProducerSequence != state.NextSequence() || block.PreviousBlockID != state.lastID {
		return protocol.SealRequest{}, fmt.Errorf("block does not extend producer history")
	}
	body, err := protocol.EncodeBlock(block)
	if err != nil {
		return protocol.SealRequest{}, err
	}
	randomID := make([]byte, 16)
	if _, err := rand.Read(randomID); err != nil {
		return protocol.SealRequest{}, fmt.Errorf("generate request ID: %w", err)
	}
	request, _, err := protocol.NewSealRequest(hex.EncodeToString(randomID), body)
	if err != nil {
		return protocol.SealRequest{}, err
	}
	data, err := protocol.MarshalJSONLine(queuedArtifact{Request: request})
	if err != nil {
		return protocol.SealRequest{}, err
	}
	path := artifactPath(state.queueDir(), block.ProducerSequence)
	if err := durable.WriteFile(path, data, 0o640); err != nil {
		return protocol.SealRequest{}, err
	}
	state.queued[block.ProducerSequence] = request
	state.lastBlock = block
	state.lastID = protocol.BlockID(body)
	state.lastCursor = block.LastCursor
	return request, nil
}

func (state *ProducerStore) PersistSeal(request protocol.SealRequest, response protocol.SealResponse) error {
	block, _, err := protocol.DecodeSealRequest(request)
	if err != nil {
		return err
	}
	queued, found := state.queued[block.ProducerSequence]
	if !found || queued != request {
		return fmt.Errorf("response is not for a pending request")
	}
	if state.requireAuthenticatedBinding && state.pinnedKey == nil {
		return fmt.Errorf("sealer key has no authenticated GIVC binding")
	}
	key, err := protocol.VerifySealResponse(request, response, state.pinnedKey)
	if err != nil {
		return err
	}
	if state.pinnedKey == nil {
		if err := durable.WriteFile(state.pinPath(), key, 0o640); err != nil {
			return fmt.Errorf("pin sealer public key: %w", err)
		}
		state.pinnedKey = key
	}
	entry := protocol.LedgerEntry{Request: request, Response: response}
	data, err := protocol.MarshalJSONLine(entry)
	if err != nil {
		return err
	}
	if err := durable.WriteFile(artifactPath(state.sealedDir(), block.ProducerSequence), data, 0o640); err != nil {
		return fmt.Errorf("persist sealed artifact: %w", err)
	}
	if err := durable.Remove(artifactPath(state.queueDir(), block.ProducerSequence)); err != nil {
		return fmt.Errorf("remove queued artifact: %w", err)
	}
	delete(state.queued, block.ProducerSequence)
	state.artifacts[block.ProducerSequence] = entry
	return nil
}

func (state *ProducerStore) queueDir() string  { return filepath.Join(state.root, "queue") }
func (state *ProducerStore) sealedDir() string { return filepath.Join(state.root, "sealed") }
func (state *ProducerStore) pinPath() string   { return filepath.Join(state.root, "sealer-public-key") }

func artifactPath(dir string, sequence uint64) string {
	return filepath.Join(dir, fmt.Sprintf("%020d.json", sequence))
}

func forEachArtifact(dir string, visit func(path string, data []byte) error) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read artifact %s: %w", path, err)
		}
		if err := visit(path, data); err != nil {
			return err
		}
	}
	return nil
}
