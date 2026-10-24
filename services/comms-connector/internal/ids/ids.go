// Package ids validates the identifiers that cross the connector boundary.
// A connection ref becomes a directory name and a URL path segment, so it is
// checked before it reaches either.
package ids

import "regexp"

// Connection refs are ServiceConnection public ids as Rails mints them:
// "svc_" and the row id. The alphabet cannot traverse a path.
var connRef = regexp.MustCompile(`^svc_[1-9][0-9]{0,18}$`)

// Command ids are SecureRandom.hex(16) on the Rails side.
var commandID = regexp.MustCompile(`^[0-9a-f]{32}$`)

// E.164 phone numbers, as Rails normalises them for pair_phone: "+", a
// country code that does not start with 0, at most 15 digits in all.
var e164 = regexp.MustCompile(`^\+[1-9][0-9]{6,14}$`)

// Phone request ids are SecureRandom.hex(8) on the Rails side: one per
// phone pairing request, never derived from the number.
var phoneRequest = regexp.MustCompile(`^[0-9a-f]{16}$`)

// Send ids are the house CommsSend public ids: at most 64 characters of
// [A-Za-z0-9_-].
var sendID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// Message ids are what whatsmeow.GenerateMessageID (send.go:73-75 in the
// pinned version) returns: WebMessageIDPrefix "3EB0" and 8 random bytes as
// upper-case hex, 20 characters. Rails mints them; the connector passes
// them unchanged as SendRequestExtra.ID.
var messageID = regexp.MustCompile(`^3EB0[0-9A-F]{16}$`)

func ValidConnectionRef(s string) bool { return connRef.MatchString(s) }
func ValidCommandID(s string) bool     { return commandID.MatchString(s) }
func ValidE164(s string) bool          { return e164.MatchString(s) }
func ValidPhoneRequest(s string) bool  { return phoneRequest.MatchString(s) }
func ValidSendID(s string) bool        { return sendID.MatchString(s) }
func ValidMessageID(s string) bool     { return messageID.MatchString(s) }
