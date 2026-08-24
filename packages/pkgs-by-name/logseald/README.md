<!--
SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# logseald

`logseald` provides clock-independent tamper evidence for Ghaf journals. A
producer on each logging-enabled host and virtual machine builds a local block
chain. A central sealer in `admin-vm` validates and signs those blocks.

Log sealing is independent of journal forwarding and systemd journal Forward
Secure Sealing (FSS). It does not change the journal format or prevent logs from
appearing in Grafana.

## Architecture

| Role | Location | Responsibility |
| --- | --- | --- |
| Producer | Host and every logging-enabled VM | Read local journal records, build chained blocks, queue them durably, and verify returned seals |
| Sealer | `admin-vm` | Authenticate producers, validate complete blocks, enforce chain order, sign seals, and persist the central ledger |

The producer reads the journal export stream and preserves duplicate and binary
fields. It creates a canonical encoding for each record, calculates a Merkle
root, and includes the previous block identifier in the next block. The journal
cursor advances only after the complete block is stored in the durable queue.

The producer submits the complete block over mutually authenticated TLS. The
sealer decodes the records and recomputes the Merkle root and block identifier.
It also checks the producer sequence and predecessor against the authenticated
chain head. Accepted blocks receive a device-wide seal sequence and an Ed25519
signature. The sealer writes the ledger entry to durable storage before it
returns the seal.

The sealer certifies its Ed25519 signing key with the authenticated GIVC
transport key. The producer verifies this binding against the GIVC certificate
from the TLS connection before it pins the signing key or accepts a seal. It
then stores the sealed artifact and removes the queued request. Repeated
delivery of the same request returns the original seal. A request identifier
reused with different content is rejected.

## Offline and Clock-Independent Operation

Block order, block closure, chaining, and signatures do not use wall-clock
time. If `admin-vm` is unavailable, each producer continues to create blocks in
its local queue. At the configured queue limit, the producer stops consuming
new journal entries and retries delivery. Journald remains the source for
records that the producer has not consumed.

The default `static-cert` TLS policy verifies the GIVC certificate authority,
peer identity, signatures, and key usage without trusting the system clock. It
does not enforce certificate expiration. Certificate replacement and revocation
must therefore be handled as explicit deployment operations.

## Identity and Keys

Logseald uses the existing GIVC certificate authority and node identity:

- `/etc/givc/ca-cert.pem`
- `/etc/givc/cert.pem`
- `/etc/givc/key.pem`

The NixOS module passes these files to the unprivileged services through systemd
credentials. The SHA-256 fingerprint of the authenticated certificate public
key identifies the producer chain.

The GIVC CA and the `admin-vm` certificate identity are the initial root of
trust. The GIVC transport key is separate from the Ed25519 log-signing key at
`/var/lib/logseald/sealer/sealer.key`. The transport key authenticates the node
and signs the key-binding statement once per sealer start. The Ed25519 key signs
the log seals.

PID 1 owns configurable TCP port `59631` on the internal `admin-vm` address and
passes traffic through an unprivileged socket proxy to the sealer's protected
Unix socket. The TCP port remains reserved while the sealer stops or restarts.
The Ghaf firewall admits the port only from configured internal node addresses;
mTLS remains the producer authentication boundary.

## Configuration

Logseald is enabled when global logging is enabled. Disable it without removing
its stored state with:

```nix
ghaf.global-config.logging.logseald.enable = false;
```

The port is also configurable:

```nix
ghaf.global-config.logging.logseald.port = 59631;
```

The local service module exposes block size, block interval, offline queue
depth, retry interval, endpoint, TLS policy, and state directory options under
`ghaf.logging.logseald`.

## Services and State

| Component | Service | State directory |
| --- | --- | --- |
| Host producer | `logseald-producer.service` | `/persist/common/logseald/producer` |
| VM producer | `logseald-producer.service` | `/var/lib/logseald/producer` |
| Admin VM sealer | `logseald-sealer.service` | `/var/lib/logseald/sealer` |
| Admin VM listener | `logseald-sealer.socket`, `logseald-sealer-proxy.service` | `/run/logseald-sealer/sealer.sock` |

Producer state contains queued requests, sealed artifacts, and the pinned
sealer public key. Sealer state contains the signing key and append-only ledger.

## Verification

Verify the producer on the host:

```console
sudo logseald verify-producer \
  --state-dir /persist/common/logseald/producer \
  --cert /etc/givc/cert.pem \
  --source "$(hostname)"
```

Verify a VM producer:

```console
sudo logseald verify-producer \
  --state-dir /var/lib/logseald/producer \
  --cert /etc/givc/cert.pem \
  --source "$(hostname)"
```

Verify the central ledger in `admin-vm`:

```console
sudo logseald verify-sealer --state-dir /var/lib/logseald/sealer
```

The commands fail if canonical block decoding, the Merkle root, a chain
predecessor, a sequence, a pinned key, or a signature is invalid.

## Security Properties and Limitations

Logseald detects modification, insertion, reordering, gaps, and forks within
the retained producer and sealer evidence. Mutual TLS prevents an unauthenticated
node from claiming another producer chain. Durable writes and idempotent retries
preserve a single accepted history across process failures.

Logseald does not encrypt journal contents, prove that a producer emitted every
event, prove that an event is truthful, or prevent a compromised producer from
stopping. The software signing key and ledger do not provide hardware-backed
rollback resistance. Restoring or deleting a complete trailing state can escape
local detection. Static certificate verification does not enforce expiration or
revocation. Producer and sealer evidence retains complete journal records and
has no automatic pruning policy.

Compromise of the Admin VM GIVC private key or CA can authorize a different
signing-key binding. Port reservation depends on PID 1 and the socket unit; an
administrator that stops the socket unit can release the port.

The cryptographic format is specific to Ghaf and has not received an external
cryptographic audit.

## References

- [Cryptographic Support for Secure Logs on Untrusted Machines](https://www.usenix.org/conference/7th-usenix-security-symposium/cryptographic-support-secure-logs-untrusted-machines)
- [Efficient Data Structures for Tamper-Evident Logging](https://www.usenix.org/conference/usenixsecurity09/technical-sessions/presentation/efficient-data-structures-tamper-evident)
- [RFC 9162: Certificate Transparency Version 2.0](https://www.rfc-editor.org/rfc/rfc9162.html)
