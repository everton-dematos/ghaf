// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

package producer

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"

	"github.com/tiiuae/ghaf/logseald/internal/protocol"
	"github.com/tiiuae/ghaf/logseald/internal/store"
)

type Engine struct {
	state       *store.ProducerStore
	maxRecords  int
	maxPending  int
	records     [][]byte
	bootID      string
	firstCursor string
	lastCursor  string
}

func Open(stateDir, chainID, sourceName string, maxRecords, maxPending int) (*Engine, error) {
	if maxRecords < 1 || maxRecords > protocol.MaxBlockRecords {
		return nil, fmt.Errorf("block record limit must be between 1 and %d", protocol.MaxBlockRecords)
	}
	if maxPending < 1 {
		return nil, fmt.Errorf("pending block limit must be positive")
	}
	state, err := store.OpenProducer(stateDir, chainID, sourceName)
	if err != nil {
		return nil, err
	}
	if state.QueueDepth() > maxPending {
		return nil, fmt.Errorf("existing queue depth %d exceeds configured limit %d", state.QueueDepth(), maxPending)
	}
	state.RequireAuthenticatedKeyBinding()
	return &Engine{state: state, maxRecords: maxRecords, maxPending: maxPending}, nil
}

func (engine *Engine) LastCursor() string { return engine.state.LastCursor() }
func (engine *Engine) QueueDepth() int    { return engine.state.QueueDepth() }
func (engine *Engine) CanRead() bool      { return engine.state.QueueDepth() < engine.maxPending }
func (engine *Engine) HasBatch() bool     { return len(engine.records) != 0 }

// Append adds one record and durably queues a block when it reaches the block
// size. The caller must stop reading while CanRead reports false.
func (engine *Engine) Append(record protocol.Record) error {
	if !engine.CanRead() {
		return fmt.Errorf("producer pending queue is full")
	}
	cursor, err := protocol.UniqueField(record, "__CURSOR")
	if err != nil {
		return err
	}
	bootID, err := protocol.UniqueField(record, "_BOOT_ID")
	if err != nil {
		return err
	}
	if len(engine.records) != 0 && bootID != engine.bootID {
		return fmt.Errorf("journal boot ID changed while producer was running")
	}
	encoded, err := protocol.EncodeRecord(record)
	if err != nil {
		return err
	}
	if len(engine.records) == 0 {
		engine.bootID, engine.firstCursor = bootID, cursor
	}
	engine.lastCursor = cursor
	engine.records = append(engine.records, encoded)
	if len(engine.records) >= engine.maxRecords {
		return engine.Flush()
	}
	return nil
}

// Flush durably writes the current batch before advancing the recoverable
// journal cursor represented by the ProducerStore.
func (engine *Engine) Flush() error {
	if len(engine.records) == 0 {
		return nil
	}
	if !engine.CanRead() {
		return fmt.Errorf("producer pending queue is full")
	}
	block := protocol.Block{
		ChainID:          engine.state.ChainID(),
		SourceName:       engine.state.SourceName(),
		ProducerSequence: engine.state.NextSequence(),
		PreviousBlockID:  engine.state.PreviousBlockID(),
		BootID:           engine.bootID,
		FirstCursor:      engine.firstCursor,
		LastCursor:       engine.lastCursor,
		Records:          engine.records,
		MerkleRoot:       protocol.MerkleRoot(engine.records),
	}
	if _, err := engine.state.Enqueue(block); err != nil {
		return err
	}
	engine.records = nil
	engine.bootID, engine.firstCursor, engine.lastCursor = "", "", ""
	return nil
}

func (engine *Engine) SubmitOne(ctx context.Context, client *http.Client, endpoint string) (bool, error) {
	pending := engine.state.Pending()
	if len(pending) == 0 {
		return false, nil
	}
	request := pending[0]
	body, err := json.Marshal(request)
	if err != nil {
		return false, err
	}
	httpRequest, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return false, err
	}
	httpRequest.Header.Set("Content-Type", "application/json")
	response, err := client.Do(httpRequest)
	if err != nil {
		return false, fmt.Errorf("submit block: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		message, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		return false, fmt.Errorf("sealer returned %s: %s", response.Status, bytes.TrimSpace(message))
	}
	if response.TLS == nil || len(response.TLS.PeerCertificates) == 0 {
		return false, fmt.Errorf("sealer response has no authenticated GIVC identity")
	}
	binding, err := protocol.DecodeKeyBindingHeader(response.Header.Get(protocol.KeyBindingHeader))
	if err != nil {
		return false, fmt.Errorf("validate sealer key binding: %w", err)
	}
	boundKey, err := protocol.VerifyKeyBinding(binding, response.TLS.PeerCertificates[0])
	if err != nil {
		return false, fmt.Errorf("validate sealer key binding: %w", err)
	}
	decoder := json.NewDecoder(io.LimitReader(response.Body, 1<<20))
	decoder.DisallowUnknownFields()
	var seal protocol.SealResponse
	if err := decoder.Decode(&seal); err != nil {
		return false, fmt.Errorf("decode sealer response: %w", err)
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return false, fmt.Errorf("sealer response contains trailing data")
	}
	if _, err := protocol.VerifySealResponse(request, seal, boundKey); err != nil {
		return false, fmt.Errorf("verify seal against authenticated key binding: %w", err)
	}
	if err := engine.state.TrustSealerKey(boundKey); err != nil {
		return false, err
	}
	if err := engine.state.PersistSeal(request, seal); err != nil {
		return false, err
	}
	return true, nil
}
