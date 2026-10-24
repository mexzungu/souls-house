package server

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"services/comms-connector/internal/command"
	"services/comms-connector/internal/ids"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/worker"
)

// MaxCommandBytes bounds a command body. The largest is send_text: 4096
// characters of text, which JSON can spell in up to 12 bytes each (a
// character outside the BMP as an escaped surrogate pair), 48 KiB, and a
// little envelope.
const MaxCommandBytes = 64 << 10

// MaxSendText is the longest send_text, in characters (Unicode code
// points, as Ruby's String#length counts them).
const MaxSendText = 4096

// Commands is what the handler drives (the Manager).
type Commands interface {
	StartPairing(ctx context.Context, ref, secret string, version int64) error
	Unpair(ctx context.Context, ref string) error
	PairPhone(ctx context.Context, ref, phone string, attempt int64, request string, seq int64) error
	SendText(ctx context.Context, ref string, req worker.SendRequest) (worker.SendResult, error)
}

type Handler struct {
	Verifier *command.Verifier
	Commands Commands
	Log      *slog.Logger
}

// ServeHTTP: POST /connections/{ref}/{start_pairing|unpair|pair_phone|send_text},
// GET /healthz. Bodies (which can carry a secret, a phone number, a chat
// or a text) are never logged; refusals log a fixed code.
func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet && r.URL.Path == "/healthz" {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/"), "/")
	if r.Method != http.MethodPost || len(parts) != 3 || parts[0] != "connections" || !ids.ValidConnectionRef(parts[1]) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	ref, op := parts[1], parts[2]
	if op != "start_pairing" && op != "unpair" && op != "pair_phone" && op != "send_text" {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown_operation"})
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxCommandBytes))
	if err != nil {
		h.refuse(w, op, "body_too_large", http.StatusRequestEntityTooLarge)
		return
	}
	cmd, err := h.Verifier.Verify(ref, op, r.Header, raw)
	clear(raw)
	var refused *command.Refused
	if errors.As(err, &refused) {
		h.refuse(w, op, refused.Code, http.StatusUnauthorized)
		return
	}
	if err != nil {
		h.refuse(w, op, "verify_failed", http.StatusUnauthorized)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	switch op {
	case "start_pairing":
		if cmd.CallbackSecret == "" || len(cmd.CallbackSecret) > 256 {
			h.refuse(w, op, "bad_secret", http.StatusUnprocessableEntity)
			return
		}
		version := max(cmd.CallbackSecretVersion, 1)
		err = h.Commands.StartPairing(ctx, ref, cmd.CallbackSecret, version)
		if errors.Is(err, worker.ErrStaleSecret) {
			h.refuse(w, op, "stale_secret_version", http.StatusConflict)
			return
		}
		if err != nil {
			h.refuse(w, op, "start_failed", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "pairing"})
	case "unpair":
		if err := h.Commands.Unpair(ctx, ref); err != nil {
			h.refuse(w, op, "unpair_failed", http.StatusInternalServerError)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "unpaired"})
	case "pair_phone":
		// Accepted, not answered: the code (or why there is none) follows
		// as a signed event, as QR codes do.
		if !ids.ValidE164(cmd.PhoneNumber) {
			h.refuse(w, op, "bad_phone_number", http.StatusUnprocessableEntity)
			return
		}
		if cmd.Attempt < 1 {
			h.refuse(w, op, "bad_attempt", http.StatusUnprocessableEntity)
			return
		}
		if !ids.ValidPhoneRequest(cmd.PhoneRequest) {
			h.refuse(w, op, "bad_request_id", http.StatusUnprocessableEntity)
			return
		}
		if cmd.PhoneRequestSeq < 1 {
			h.refuse(w, op, "bad_request_seq", http.StatusUnprocessableEntity)
			return
		}
		err := h.Commands.PairPhone(ctx, ref, strings.TrimPrefix(cmd.PhoneNumber, "+"), cmd.Attempt, cmd.PhoneRequest, cmd.PhoneRequestSeq)
		switch {
		case errors.Is(err, worker.ErrStaleAttempt):
			h.refuse(w, op, "stale_attempt", http.StatusConflict)
		case errors.Is(err, worker.ErrStaleRequest):
			// A newer request already reached this connector (commands can
			// arrive out of Rails' order): this one is not run, and the
			// newer one keeps running.
			h.refuse(w, op, "stale_request", http.StatusConflict)
		case errors.Is(err, worker.ErrNotPairing):
			h.refuse(w, op, "not_pairing", http.StatusConflict)
		case err != nil:
			h.refuse(w, op, "pair_phone_failed", http.StatusInternalServerError)
		default:
			writeJSON(w, http.StatusAccepted, map[string]string{"status": "requested"})
		}
	case "send_text":
		h.sendText(ctx, w, ref, cmd)
	}
}

// sendText: the fields are checked first (422, nothing recorded), then the
// worker runs the send (worker.SendText). The answers are the send_text
// contract's; anything else, including a 502 send_unknown, Rails treats as
// unknown and never retries.
func (h *Handler) sendText(ctx context.Context, w http.ResponseWriter, ref string, cmd command.Command) {
	const op = "send_text"
	if cmd.Attempt < 1 {
		h.refuse(w, op, "bad_attempt", http.StatusUnprocessableEntity)
		return
	}
	if !ids.ValidSendID(cmd.SendID) {
		h.refuse(w, op, "bad_send_id", http.StatusUnprocessableEntity)
		return
	}
	if !ids.ValidMessageID(cmd.MessageID) {
		h.refuse(w, op, "bad_message_id", http.StatusUnprocessableEntity)
		return
	}
	if _, err := provider.ParseChat(cmd.Chat); err != nil {
		code := "bad_chat"
		if errors.Is(err, provider.ErrUnsupportedChat) {
			code = "unsupported_chat"
		}
		h.refuse(w, op, code, http.StatusUnprocessableEntity)
		return
	}
	if n := utf8.RuneCountInString(cmd.Text); n < 1 || n > MaxSendText || !utf8.ValidString(cmd.Text) {
		h.refuse(w, op, "bad_text", http.StatusUnprocessableEntity)
		return
	}
	res, err := h.Commands.SendText(ctx, ref, worker.SendRequest{Attempt: cmd.Attempt, SendID: cmd.SendID,
		MessageID: cmd.MessageID, Chat: cmd.Chat, Text: cmd.Text})
	var refused *worker.SendRefused
	switch {
	case err == nil:
		writeJSON(w, http.StatusOK, map[string]string{"status": "sent", "message_id": res.MessageID, "sent_at": res.SentAt})
	case errors.Is(err, worker.ErrNotConnected):
		h.refuse(w, op, "not_connected", http.StatusConflict)
	case errors.Is(err, worker.ErrStaleAttempt):
		h.refuse(w, op, "stale_attempt", http.StatusConflict)
	case errors.Is(err, worker.ErrOutcomeUnknown):
		h.refuse(w, op, "outcome_unknown", http.StatusConflict)
	case errors.Is(err, worker.ErrSendMismatch):
		h.refuse(w, op, "send_mismatch", http.StatusUnprocessableEntity)
	case errors.As(err, &refused):
		h.Log.Warn("command refused", slog.String("op", op), slog.String("reason", "refused"), slog.String("refused", refused.Reason))
		writeJSON(w, http.StatusUnprocessableEntity, map[string]string{"error": "refused", "reason": refused.Reason})
	case errors.Is(err, worker.ErrSendUnknown):
		h.refuse(w, op, "send_unknown", http.StatusBadGateway)
	default:
		// A store failure before anything was sent, or anything else.
		h.refuse(w, op, "send_failed", http.StatusInternalServerError)
	}
}

func (h *Handler) refuse(w http.ResponseWriter, op, code string, status int) {
	h.Log.Warn("command refused", slog.String("op", op), slog.String("reason", code))
	writeJSON(w, status, map[string]string{"error": code})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// ErrTLS is the only error TLSConfig returns: paths and parse errors stay out.
var ErrTLS = errors.New("mutual TLS is not configured correctly")

// TLSConfig builds the server side of the mutual TLS Rails expects
// (CommsConnector.tls_options): the connector's certificate, and client
// certificates required and verified against the house CA. clientName,
// when set, must be the client certificate's common name or a DNS SAN.
func TLSConfig(certFile, keyFile, clientCAFile, clientName string) (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, ErrTLS
	}
	pem, err := os.ReadFile(clientCAFile)
	if err != nil {
		return nil, ErrTLS
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(pem) {
		return nil, ErrTLS
	}
	cfg := &tls.Config{
		MinVersion:   tls.VersionTLS12,
		Certificates: []tls.Certificate{cert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    pool,
	}
	if clientName != "" {
		cfg.VerifyConnection = func(cs tls.ConnectionState) error {
			if len(cs.PeerCertificates) == 0 {
				return ErrTLS
			}
			leaf := cs.PeerCertificates[0]
			if leaf.Subject.CommonName == clientName {
				return nil
			}
			for _, n := range leaf.DNSNames {
				if n == clientName {
					return nil
				}
			}
			return errors.New("client certificate is not Rails's")
		}
	}
	return cfg, nil
}
