package ids

import (
	"strings"
	"testing"

	"go.mau.fi/whatsmeow"
)

func TestConnectionRefs(t *testing.T) {
	for _, ok := range []string{"svc_1", "svc_12", "svc_9223372036854775807"} {
		if !ValidConnectionRef(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "svc_", "svc_0", "svc_01", "svc_1/../x", "../svc_1", "svc_1\n", "SVC_1", "svc_12345678901234567890", "svc_-1"} {
		if ValidConnectionRef(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestCommandIDs(t *testing.T) {
	if !ValidCommandID("0123456789abcdef0123456789abcdef") {
		t.Error("valid id refused")
	}
	for _, bad := range []string{"", "0123456789ABCDEF0123456789abcdef", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdef0"} {
		if ValidCommandID(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestE164(t *testing.T) {
	for _, ok := range []string{"+447700900123", "+12025550123", "+3361234567", "+999999999999999"} {
		if !ValidE164(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", "447700900123", "+0447700900123", "+44 7700 900123", "+44-7700900123",
		"+12345", "+1234567890123456", "+44770090012a", "+447700900123\n", "++447700900123"} {
		if ValidE164(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestSendIDs(t *testing.T) {
	for _, ok := range []string{"a", "snd_1", "Ab-_9", strings.Repeat("x", 64)} {
		if !ValidSendID(ok) {
			t.Errorf("%q refused", ok)
		}
	}
	for _, bad := range []string{"", strings.Repeat("x", 65), "snd 1", "snd/1", "snd.1", "snd_1\n", "é"} {
		if ValidSendID(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}

// The accepted message id is exactly what the pinned whatsmeow's
// GenerateMessageID returns.
func TestMessageIDsAreWhatsmeowsShape(t *testing.T) {
	for i := 0; i < 2000; i++ {
		if id := string(whatsmeow.GenerateMessageID()); !ValidMessageID(id) {
			t.Fatalf("whatsmeow's own id %q refused", id)
		}
	}
	for _, bad := range []string{"", "3EB0", "3EB00123456789ABCDE", "3EB00123456789ABCDEF0", "3eb00123456789abcdef",
		"3EB00123456789abcdef", "4EB00123456789ABCDEF", "3EB00123456789ABCDEG", "3EB00123456789ABCDEF\n",
		"3EB0123456789ABCDEF012", // the 22-character form cli.GenerateMessageID makes
	} {
		if ValidMessageID(bad) {
			t.Errorf("%q accepted", bad)
		}
	}
}
