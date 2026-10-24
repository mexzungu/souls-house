package provider

import (
	"errors"
	"testing"
)

func TestParseChat(t *testing.T) {
	for _, ok := range []string{
		"447700900002@s.whatsapp.net", // as canonical() reports a direct chat
		"123456789012345@lid",         // a hidden user whose number is unknown
		"120363000000000001@g.us",
		"447700900000-1600000000@g.us", // an old-style group id
	} {
		if jid, err := ParseChat(ok); err != nil || jid.String() != ok {
			t.Errorf("%q refused: %v", ok, err)
		}
	}
	for _, bad := range []string{
		"", "447700900002", "@s.whatsapp.net", "447700900002@", "+447700900002@s.whatsapp.net",
		"447700900002:3@s.whatsapp.net", "447700900002.0:3@s.whatsapp.net", "alice@s.whatsapp.net",
		"447700900002@s.whatsapp.net ", "a@b@c", "12345abc@lid", "1:2@lid",
	} {
		if _, err := ParseChat(bad); !errors.Is(err, ErrBadChat) {
			t.Errorf("%q: %v", bad, err)
		}
	}
	for _, unsupported := range []string{
		"status@broadcast", "1600000000@broadcast", "120363000000000002@newsletter",
		"867051314767696@bot", "13135550002@s.whatsapp.net", "447700900002@c.us", "1@msgr", "1@hosted",
	} {
		if _, err := ParseChat(unsupported); !errors.Is(err, ErrUnsupportedChat) {
			t.Errorf("%q: %v", unsupported, err)
		}
	}
}
