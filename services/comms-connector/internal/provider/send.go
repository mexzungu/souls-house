package provider

import (
	"errors"

	"go.mau.fi/whatsmeow/types"
)

// Chat refusals for send_text, before anything is recorded or sent.
var (
	// ErrBadChat: not a JID in the form the connector reports chats in.
	ErrBadChat = errors.New("chat is not a valid chat id")
	// ErrUnsupportedChat: a JID the connector does not send to (status
	// updates, broadcast lists, newsletters, bots and other servers).
	ErrUnsupportedChat = errors.New("chat cannot be sent to")
)

// ParseChat checks a send_text chat: it must be a JID exactly as the
// connector reports chats in its events (whatsapp.handler.canonical, then
// JID.String(): no device or agent part), on a server the connector sends
// to: a phone-number user (s.whatsapp.net), a hidden user (lid) or a group
// (g.us).
func ParseChat(chat string) (types.JID, error) {
	if chat == "" || len(chat) > 128 {
		return types.JID{}, ErrBadChat
	}
	jid, err := types.ParseJID(chat)
	if err != nil || jid.User == "" || jid.Server == "" || jid.Device != 0 || jid.RawAgent != 0 || jid.String() != chat {
		return types.JID{}, ErrBadChat
	}
	switch jid.Server {
	case types.DefaultUserServer:
		if jid.IsBot() {
			return types.JID{}, ErrUnsupportedChat
		}
		if !digits(jid.User) {
			return types.JID{}, ErrBadChat
		}
	case types.HiddenUserServer:
		if !digits(jid.User) {
			return types.JID{}, ErrBadChat
		}
	case types.GroupServer:
	case types.BroadcastServer, types.NewsletterServer, types.BotServer, types.HostedServer, types.HostedLIDServer,
		types.MessengerServer, types.InteropServer, types.LegacyUserServer:
		// broadcast (status@broadcast and broadcast lists), newsletter,
		// bot, hosted, msgr, interop, c.us: real, but not sent to.
		return types.JID{}, ErrUnsupportedChat
	default:
		return types.JID{}, ErrBadChat
	}
	return jid, nil
}

func digits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// RefusedError is a send that certainly did not go out: WhatsApp refused it
// before accepting it, or it was stopped before anything of the message
// left the connector. Reason is a fixed machine word (Refused* below),
// never WhatsApp's error text, which can name the recipient.
type RefusedError struct{ Reason string }

func (e *RefusedError) Error() string { return "send refused: " + e.Reason }

// Refusal reasons.
const (
	RefusedNotConnected          = "not_connected"
	RefusedBadChat               = "bad_chat"
	RefusedUnsupportedChat       = "unsupported_chat"
	RefusedNotOnWhatsApp         = "not_on_whatsapp"
	RefusedRecipientLookupFailed = "recipient_lookup_failed"
	RefusedGroupLookupFailed     = "group_lookup_failed"
)

// ErrSendUnknown: the message may or may not have gone out (a timeout, a
// lost connection, a server error after sending, anything not known to be
// a refusal). The caller must never send it again.
var ErrSendUnknown = errors.New("send outcome unknown")
