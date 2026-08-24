// SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
// SPDX-License-Identifier: Apache-2.0

// Package tlsutil builds TLS configurations whose identity checks can work
// before the system wall clock is trustworthy.
package tlsutil

import (
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"os"
)

type TimePolicy string

const (
	WallClock  TimePolicy = "wall-clock"
	StaticCert TimePolicy = "static-cert"
)

func ParseTimePolicy(value string) (TimePolicy, error) {
	policy := TimePolicy(value)
	if policy != WallClock && policy != StaticCert {
		return "", fmt.Errorf("unknown TLS time policy %q", value)
	}
	return policy, nil
}

func LoadRoots(path string) (*x509.CertPool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read CA bundle: %w", err)
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(data) {
		return nil, fmt.Errorf("CA bundle contains no certificates")
	}
	return pool, nil
}

func LoadLeaf(path string) (*x509.Certificate, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read certificate: %w", err)
	}
	block, _ := pem.Decode(data)
	if block == nil || block.Type != "CERTIFICATE" {
		return nil, fmt.Errorf("certificate file contains no certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse certificate: %w", err)
	}
	return cert, nil
}

func ChainID(cert *x509.Certificate) string {
	hash := sha256.Sum256(cert.RawSubjectPublicKeyInfo)
	return "spki-sha256:" + hex.EncodeToString(hash[:])
}

func ClientConfig(certFile, keyFile, caFile, serverName string, policy TimePolicy) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load client key pair: %w", err)
	}
	roots, err := LoadRoots(caFile)
	if err != nil {
		return nil, err
	}
	config := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
		RootCAs:      roots,
		ServerName:   serverName,
	}
	if policy == StaticCert {
		config.InsecureSkipVerify = true // Verification is performed below with a clock-independent reference time.
		config.VerifyConnection = func(connection tls.ConnectionState) error {
			return verifyPeer(connection.PeerCertificates, roots, serverName, x509.ExtKeyUsageServerAuth)
		}
	}
	return config, nil
}

func ServerConfig(certFile, keyFile, caFile string, policy TimePolicy) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load server key pair: %w", err)
	}
	roots, err := LoadRoots(caFile)
	if err != nil {
		return nil, err
	}
	config := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS13,
		ClientCAs:    roots,
		ClientAuth:   tls.RequireAndVerifyClientCert,
	}
	if policy == StaticCert {
		config.ClientAuth = tls.RequireAnyClientCert
		config.VerifyConnection = func(connection tls.ConnectionState) error {
			return verifyPeer(connection.PeerCertificates, roots, "", x509.ExtKeyUsageClientAuth)
		}
	}
	return config, nil
}

// verifyPeer verifies signatures, names and key usage, but chooses a time from
// the certificates' common validity interval instead of trusting the device's
// wall clock. Certificate revocation/rotation is therefore an operational
// responsibility in static-cert mode.
func verifyPeer(peer []*x509.Certificate, roots *x509.CertPool, name string, usage x509.ExtKeyUsage) error {
	if len(peer) == 0 {
		return fmt.Errorf("TLS peer sent no certificate")
	}
	notBefore, notAfter := peer[0].NotBefore, peer[0].NotAfter
	intermediates := x509.NewCertPool()
	for _, cert := range peer[1:] {
		intermediates.AddCert(cert)
		if cert.NotBefore.After(notBefore) {
			notBefore = cert.NotBefore
		}
		if cert.NotAfter.Before(notAfter) {
			notAfter = cert.NotAfter
		}
	}
	if !notBefore.Before(notAfter) {
		return fmt.Errorf("TLS certificate chain has no common validity interval")
	}
	verificationTime := notBefore.Add(notAfter.Sub(notBefore) / 2)
	_, err := peer[0].Verify(x509.VerifyOptions{
		DNSName:       name,
		Roots:         roots,
		Intermediates: intermediates,
		CurrentTime:   verificationTime,
		KeyUsages:     []x509.ExtKeyUsage{usage},
	})
	if err != nil {
		return fmt.Errorf("verify TLS peer: %w", err)
	}
	return nil
}

func LeafFromTLSCertificate(cert tls.Certificate) (*x509.Certificate, error) {
	if cert.Leaf != nil {
		return cert.Leaf, nil
	}
	if len(cert.Certificate) == 0 {
		return nil, fmt.Errorf("TLS key pair has no leaf certificate")
	}
	return x509.ParseCertificate(cert.Certificate[0])
}
