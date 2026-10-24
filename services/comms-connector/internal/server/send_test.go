package server

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"testing"
	"time"

	"services/comms-connector/internal/command"
	"services/comms-connector/internal/provider"
	"services/comms-connector/internal/sig"
)

const (
	cmdKey      = "test-command-key"
	sendChat    = "447700900001@s.whatsapp.net" // synthetic chat 1, as reported in its events
	okMsgID     = "3EB0000000000000AAAA"
	refuseMsgID = "3EB0000000000000BBBB"
	unsureMsgID = "3EB0000000000000CCCC"
)

// commandServer serves the handler over the manager, as main does, with
// the rig's logger.
func (r *rig) commandServer(m *Manager) *httptest.Server {
	log := slog.New(slog.NewJSONHandler(r.logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	srv := httptest.NewServer(&Handler{
		Verifier: command.NewVerifier("k1", []byte(cmdKey), func() time.Time { return time.Now().Add(-time.Second) }),
		Commands: m, Log: log,
	})
	r.t.Cleanup(srv.Close)
	return srv
}

// post sends one signed command as CommsConnector.command does.
func post(t *testing.T, srv *httptest.Server, ref, op string, fields map[string]any) (int, map[string]string) {
	t.Helper()
	id, _ := sig.Nonce()
	at := strconv.FormatInt(time.Now().Unix(), 10)
	body := map[string]any{"connection": ref, "operation": op, "command_id": id, "issued_at": json.Number(at)}
	for k, v := range fields {
		body[k] = v
	}
	raw, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/connections/"+ref+"/"+op, bytes.NewReader(raw))
	req.Header.Set(sig.HeaderKeyID, "k1")
	req.Header.Set(sig.HeaderCommandID, id)
	req.Header.Set(sig.HeaderIssuedAt, at)
	req.Header.Set(sig.HeaderCommand, sig.SignCommand([]byte(cmdKey), "k1", ref, op, id, at, raw))
	resp, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	var out map[string]string
	json.Unmarshal(b, &out)
	return resp.StatusCode, out
}

func sendTo(sendID, msgID, text string) map[string]any {
	return map[string]any{"attempt": 1, "send_id": sendID, "message_id": msgID, "chat": sendChat, "text": text}
}

// One synthetic hook for the whole test, chosen by message id, so nothing
// is reconfigured while sessions run.
func outcomeByMessageID(ctx context.Context, chat, messageID, text string) (time.Time, error) {
	switch messageID {
	case refuseMsgID:
		return provider.SendRefusing(provider.RefusedNotOnWhatsApp)(ctx, chat, messageID, text)
	case unsureMsgID:
		return provider.SendAmbiguous(ctx, chat, messageID, text)
	}
	return time.Date(2026, 10, 24, 10, 0, 7, 0, time.UTC), nil
}

// send_text end to end over the handler and the manager: sent, replayed
// identically, refused, unknown and then outcome_unknown, a mismatch; and
// the echo of the sent message reaches Rails as an ordinary message event
// whose provider_message_id is the id Rails chose.
func TestSendTextEndToEndAndTheEcho(t *testing.T) {
	r := newRig(t)
	r.syn.SendHook = outcomeByMessageID
	r.rails.expect(ref, secret)
	m := r.manager()
	srv := r.commandServer(m)
	if status, out := post(t, srv, ref, "send_text", sendTo("snd_1", okMsgID, "hi")); status != 409 || out["error"] != "not_connected" {
		t.Fatalf("before pairing: %d %v", status, out)
	}
	if err := m.StartPairing(context.Background(), ref, secret, 1); err != nil {
		t.Fatal(err)
	}
	r.wantAllDelivered(15)

	text := "Reply from the house " + canary
	status, first := post(t, srv, ref, "send_text", sendTo("snd_1", okMsgID, text))
	if status != 200 || first["status"] != "sent" || first["message_id"] != okMsgID || first["sent_at"] != "2026-10-24T10:00:07Z" {
		t.Fatalf("send: %d %v", status, first)
	}
	if status, again := post(t, srv, ref, "send_text", sendTo("snd_1", okMsgID, text)); status != 200 || len(again) != 3 ||
		again["sent_at"] != first["sent_at"] || again["message_id"] != first["message_id"] {
		t.Fatalf("replay: %d %v", status, again)
	}
	if status, out := post(t, srv, ref, "send_text", sendTo("snd_1", okMsgID, text+"!")); status != 422 || out["error"] != "send_mismatch" {
		t.Fatalf("mismatch: %d %v", status, out)
	}
	if status, out := post(t, srv, ref, "send_text", sendTo("snd_2", refuseMsgID, text)); status != 422 || out["error"] != "refused" || out["reason"] != "not_on_whatsapp" {
		t.Fatalf("refused: %d %v", status, out)
	}
	if status, out := post(t, srv, ref, "send_text", sendTo("snd_3", unsureMsgID, text)); status != 502 || out["error"] != "send_unknown" {
		t.Fatalf("unknown: %d %v", status, out)
	}
	if status, out := post(t, srv, ref, "send_text", sendTo("snd_3", unsureMsgID, text)); status != 409 || out["error"] != "outcome_unknown" {
		t.Fatalf("unknown, again: %d %v", status, out)
	}
	stale := sendTo("snd_4", "3EB0000000000000DDDD", text)
	stale["attempt"] = 2
	if status, out := post(t, srv, ref, "send_text", stale); status != 409 || out["error"] != "stale_attempt" {
		t.Fatalf("stale: %d %v", status, out)
	}
	if n := r.syn.Sends(); n != 3 {
		t.Fatalf("provider called %d times, want 3 (sent, refused, unknown)", n)
	}

	eventually(t, "the echo at Rails", func() bool { return r.rails.messages(ref)[okMsgID] == 1 })
	_, _, events, _ := r.rails.snapshot(ref)
	var echo map[string]any
	for _, ev := range events {
		if ev["type"] != "message.upsert" {
			continue
		}
		for _, msg := range ev["messages"].([]any) {
			if mm := msg.(map[string]any); mm["provider_message_id"] == okMsgID {
				echo = mm
			}
		}
	}
	if echo["chat"] != sendChat || echo["body"] != text || echo["sender_id"] != provider.SyntheticOwnID+"@s.whatsapp.net" {
		t.Fatalf("echo %v", echo)
	}
	if r.rails.messages(ref)[refuseMsgID] != 0 || r.rails.messages(ref)[unsureMsgID] != 0 {
		t.Fatal("an unsent message was echoed")
	}
}

// Over the handler: after the phone logs the device out (the worker stays,
// not connected), a replay of a sent send_id still answers the identical
// 200 and a new send_id answers not_connected.
func TestReplayAfterLogoutAnswersFromTheRecord(t *testing.T) {
	r := newRig(t)
	r.syn.SendHook = outcomeByMessageID
	signal := make(chan struct{})
	r.syn.LogoutSignal = signal
	r.rails.expect(ref, secret)
	m := r.manager()
	srv := r.commandServer(m)
	m.StartPairing(context.Background(), ref, secret, 1)
	r.wantAllDelivered(15)
	status, first := post(t, srv, ref, "send_text", sendTo("snd_1", okMsgID, "hi"))
	if status != 200 {
		t.Fatalf("send: %d %v", status, first)
	}
	close(signal)
	eventually(t, "logged out", func() bool { return m.State(ref) == "logged_out" })
	status, again := post(t, srv, ref, "send_text", sendTo("snd_1", okMsgID, "hi"))
	if status != 200 || len(again) != 3 || again["sent_at"] != first["sent_at"] || again["message_id"] != first["message_id"] {
		t.Fatalf("replay after logout: %d %v", status, again)
	}
	if status, out := post(t, srv, ref, "send_text", sendTo("snd_2", refuseMsgID, "hi")); status != 409 || out["error"] != "not_connected" {
		t.Fatalf("new send after logout: %d %v", status, out)
	}
	if r.syn.Sends() != 1 {
		t.Fatalf("provider called %d times", r.syn.Sends())
	}
}
