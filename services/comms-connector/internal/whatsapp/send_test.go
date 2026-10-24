package whatsapp

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"

	"services/comms-connector/internal/provider"
)

func refusal(err error) string {
	var r *provider.RefusedError
	if errors.As(err, &r) {
		return r.Reason
	}
	if errors.Is(err, provider.ErrSendUnknown) {
		return "unknown"
	}
	return "other: " + err.Error()
}

// The real whatsmeow SendMessage, offline (no socket), against a paired
// and an unpaired device: the errors it returns before sending map to the
// refusals; the one it returns from inside sendDM stays unknown.
func TestSendMessageErrorsOffline(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	send := func(cli *whatsmeow.Client, to types.JID) error {
		_, err := cli.SendMessage(ctx, to, &waE2E.Message{Conversation: proto.String("hi " + canary)},
			whatsmeow.SendRequestExtra{ID: whatsmeow.GenerateMessageID()})
		if err == nil {
			t.Fatalf("offline send to %v succeeded", to)
		}
		return err
	}

	unpairedStore := openStore(t, filepath.Join(t.TempDir(), "u.db"), newKey())
	defer unpairedStore.Close()
	dev, _ := mustSession(t, unpairedStore).device(ctx)
	unpaired := whatsmeow.NewClient(dev, waLog.Noop)

	st := openStore(t, filepath.Join(t.TempDir(), "p.db"), newKey())
	defer st.Close()
	fakePaired(t, st)
	dev, _ = mustSession(t, st).device(ctx)
	paired := whatsmeow.NewClient(dev, waLog.Noop)
	unknownNumber := types.NewJID("447700900099", types.DefaultUserServer) // no LID cached

	for _, c := range []struct {
		name string
		cli  *whatsmeow.Client
		to   types.JID
		want string
	}{
		{"no device", unpaired, peerJID, "not_connected"},
		{"a device JID", paired, types.NewADJID(peerJID.User, 0, 3), "bad_chat"},
		{"a number with no cached LID, lookup fails", paired, unknownNumber, "recipient_lookup_failed"},
		{"a group, members lookup fails", paired, grpJID, "group_lookup_failed"},
		// The LID is cached, so SendMessage reaches sendDM, where device
		// lookup and the socket write are not told apart: unknown.
		{"a number with a cached LID", paired, peerJID, "unknown"},
		{"a LID", paired, peerLID, "unknown"},
	} {
		err := send(c.cli, c.to)
		t.Logf("%s: whatsmeow returned %q", c.name, err)
		got := sendError(err)
		if r := refusal(got); r != c.want {
			t.Errorf("%s: %s (whatsmeow said %q)", c.name, r, err)
		}
		if strings.Contains(got.Error(), "4477") || strings.Contains(got.Error(), canary) {
			t.Errorf("%s: the mapped error names the recipient: %q", c.name, got)
		}
	}
}

// The text of whatsmeow's pre-send errors, and what is never a refusal.
func TestSendErrorMapping(t *testing.T) {
	pn := types.NewJID("447700900099", types.DefaultUserServer)
	for err, want := range map[error]string{
		whatsmeow.ErrNotLoggedIn:                          "not_connected",
		whatsmeow.ErrClientIsNil:                          "not_connected",
		whatsmeow.ErrRecipientADJID:                       "bad_chat",
		fmt.Errorf("no LID found for %s from server", pn): "not_on_whatsapp",
		fmt.Errorf("failed to get user info for %s to fill LID cache: %w", pn, whatsmeow.ErrIQTimedOut): "recipient_lookup_failed",
		fmt.Errorf("failed to get LID for PN %s: %w", pn, errors.New("db")):                             "recipient_lookup_failed",
		fmt.Errorf("failed to get group members: %w", whatsmeow.ErrIQForbidden):                         "group_lookup_failed",
		fmt.Errorf("%w %d", whatsmeow.ErrServerReturnedError, 479):                                      "unknown",
		whatsmeow.ErrMessageTimedOut: "unknown",
		context.DeadlineExceeded:     "unknown",
		context.Canceled:             "unknown",
		fmt.Errorf("failed to send message node: %w", whatsmeow.ErrNotConnected):   "unknown",
		fmt.Errorf("wrapped later: %w", whatsmeow.ErrNotLoggedIn):                  "unknown",
		fmt.Errorf("retry: %w", fmt.Errorf("no LID found for %s from server", pn)): "unknown",
	} {
		if got := refusal(sendError(err)); got != want {
			t.Errorf("%q: %s, want %s", err, got, want)
		}
	}
}

// A session that is not running cannot send, and does not try.
func TestSendTextWithoutARunningSession(t *testing.T) {
	st := openStore(t, filepath.Join(t.TempDir(), "s.db"), newKey())
	defer st.Close()
	fakePaired(t, st)
	s := mustSession(t, st)
	if s.Online() {
		t.Fatal("online without Run")
	}
	_, err := s.SendText(context.Background(), peerJID.String(), "3EB00123456789ABCDEF", "hi")
	if refusal(err) != "not_connected" {
		t.Fatalf("got %v", err)
	}
	if _, err := s.SendText(context.Background(), "status@broadcast", "3EB00123456789ABCDEF", "hi"); refusal(err) != "bad_chat" {
		t.Fatalf("status: %v", err)
	}
}

// The echo: WhatsApp shows the account's own sent message as an
// events.Message with IsFromMe and the id it was sent with. It reaches
// Rails as an ordinary message whose provider_message_id is the id Rails
// chose, in the chat as the connector reports it (a LID chat mapped to the
// number, as for any message).
func TestOwnSentMessageKeepsRailsMessageID(t *testing.T) {
	st := openStore(t, filepath.Join(t.TempDir(), "store.db"), newKey())
	defer st.Close()
	fakePaired(t, st)
	dev, _ := mustSession(t, st).device(context.Background())
	sink := &recSink{}
	h := &handler{cli: whatsmeow.NewClient(dev, waLog.Noop), sink: sink, ctx: context.Background(), names: map[types.JID]bool{}}
	at := time.Date(2026, 10, 24, 10, 0, 7, 0, time.UTC)
	for id, chat := range map[string]types.JID{"3EB00123456789ABCDEF": peerJID, "3EB0FEDCBA9876543210": peerLID, "3EB000000000000000AA": grpJID} {
		e := &events.Message{Info: types.MessageInfo{ID: id, Timestamp: at,
			MessageSource: types.MessageSource{Chat: chat, Sender: ownJID, IsFromMe: true}},
			Message: &waE2E.Message{Conversation: proto.String("sent " + id)}}
		if !h.handle(e) {
			t.Fatalf("%s not acknowledged", id)
		}
	}
	got := map[string]provider.Message{}
	for _, m := range sink.msgs {
		got[m.ProviderMessageID] = m
	}
	for id, chat := range map[string]string{"3EB00123456789ABCDEF": peerJID.String(), "3EB0FEDCBA9876543210": peerJID.String(), "3EB000000000000000AA": grpJID.String()} {
		m, ok := got[id]
		if !ok || m.Chat != chat || *m.Body != "sent "+id || m.SenderID != ownJID.String() || !strings.HasPrefix(m.SenderName, "Owner") {
			t.Errorf("%s: %+v", id, m)
		}
	}
}
