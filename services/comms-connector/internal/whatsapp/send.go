package whatsapp

import (
	"context"
	"strings"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"google.golang.org/protobuf/proto"

	"services/comms-connector/internal/provider"
)

// Online: Run's client exists, has a socket and a device.
func (s *Session) Online() bool {
	s.mu.Lock()
	cli := s.cli
	s.mu.Unlock()
	return cli != nil && cli.IsConnected() && cli.IsLoggedIn()
}

// SendText sends a plain text message (Conversation) to chat with Rails'
// message id and returns WhatsApp's server timestamp.
//
// Chats are sent to in the form the connector reports them: a phone-number
// JID (whatsmeow looks up the LID itself, send.go:337-357, and sends to
// it), a LID (send.go:330-335) or a group (send.go:303-320).
//
// The error is a *provider.RefusedError only where the pinned whatsmeow
// returns it before any part of the message is sent (see refusal);
// everything else is provider.ErrSendUnknown. whatsmeow's own error text,
// which names the recipient, is never passed on.
func (s *Session) SendText(ctx context.Context, chat, messageID, text string) (time.Time, error) {
	jid, err := provider.ParseChat(chat)
	if err != nil {
		return time.Time{}, &provider.RefusedError{Reason: provider.RefusedBadChat}
	}
	s.mu.Lock()
	cli := s.cli
	s.mu.Unlock()
	if cli == nil || !cli.IsConnected() || !cli.IsLoggedIn() {
		// SendMessage is not called.
		return time.Time{}, &provider.RefusedError{Reason: provider.RefusedNotConnected}
	}
	resp, err := cli.SendMessage(ctx, jid, &waE2E.Message{Conversation: proto.String(text)},
		whatsmeow.SendRequestExtra{ID: types.MessageID(messageID)})
	if err != nil {
		return time.Time{}, sendError(err)
	}
	return resp.Timestamp, nil
}

// sendError keeps a refusal only where the pinned whatsmeow
// (v0.0.0-20261007111105-c386243a72ba, send.go) returns the error from
// SendMessage before the message node is handed to the socket: before
// sendDM/sendGroup (send.go:405-423), which is where the first byte of the
// message can go out. Every one of these is returned unwrapped, so they
// are matched on the top-level error only: an error that merely wraps one
// of them may come from later and is unknown.
//
//   - ErrClientIsNil (send.go:189-191), ErrNotLoggedIn (send.go:204-208):
//     not_connected.
//   - ErrRecipientADJID (send.go:200-203): bad_chat (ParseChat already
//     refuses device JIDs).
//   - "no LID found for … from server" (send.go:350-352): the server's
//     user info has no LID for the number, so WhatsApp has no such user:
//     not_on_whatsapp.
//   - "failed to get LID for PN …" (send.go:339-342) and "failed to get
//     user info for … to fill LID cache" (send.go:346-349): the number's
//     lookup failed before sending: recipient_lookup_failed.
//   - "failed to get group members: …" (send.go:305-310): group_lookup_failed.
//
// Not refusals, though some are early: ErrServerReturnedError (the
// server's ack carried an error code, send.go:459-461: the node was sent),
// ErrMessageTimedOut and ctx errors (send.go:441-452), every error from
// sendDM/sendGroup (encryption, device lookup and the socket write are not
// told apart), and anything from retryFrame.
func sendError(err error) error {
	switch err {
	case whatsmeow.ErrClientIsNil, whatsmeow.ErrNotLoggedIn:
		return &provider.RefusedError{Reason: provider.RefusedNotConnected}
	case whatsmeow.ErrRecipientADJID:
		return &provider.RefusedError{Reason: provider.RefusedBadChat}
	}
	msg := err.Error()
	switch {
	case strings.HasPrefix(msg, "no LID found for ") && strings.HasSuffix(msg, " from server"):
		return &provider.RefusedError{Reason: provider.RefusedNotOnWhatsApp}
	case strings.HasPrefix(msg, "failed to get LID for PN "),
		strings.HasPrefix(msg, "failed to get user info for ") && strings.Contains(msg, " to fill LID cache: "):
		return &provider.RefusedError{Reason: provider.RefusedRecipientLookupFailed}
	case strings.HasPrefix(msg, "failed to get group members: "):
		return &provider.RefusedError{Reason: provider.RefusedGroupLookupFailed}
	}
	return provider.ErrSendUnknown
}
