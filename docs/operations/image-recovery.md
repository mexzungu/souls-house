# Recover a removed or replaced avatar or site logo

This is recovery, not erasure. Removing or replacing a person's avatar or the
site logo keeps the earlier image's bytes, attached to the same owner under a
history name (`retired_avatars` on the person's Profile, `retired_logos` on the
Setting). The attachment row is the owner/version link: owner, history name,
when it was retired (`created_at`) and the blob. See
`RetainsReplacedAttachment` and issue #93.

Retained images are never served: their old signed blob and variant URLs return
404 (`HidesDiscardedBlobs`), unless the same blob is still attached to some
other live owner. A storage-service URL already handed out before removal lives
until it expires (five minutes by default).

Only a human system administrator recovers an image, and only at the owner's
request (for the logo, a site-admin decision).

1. Confirm the request against the audit log (`remove_avatar`, `set_avatar` or
   `update_settings` entries name the person and the time).
2. List the history, newest last, in a Rails console or `bin/rails runner`:

   ```ruby
   profile = User.find_by!(email_address: "...").profile
   profile.retired_avatars_attachments.order(:created_at).map { |a| [ a.blob_id, a.blob.filename.to_s, a.created_at ] }
   # site logo: Setting.instance.retired_logos_attachments...
   ```

   Show the person the filenames and dates; don't paste the image anywhere
   public.
3. Restore the chosen one: `profile.restore_retired_avatar!(blob_id)` (or
   `Setting.instance.restore_retired_logo!(blob_id)`). The image it displaces is
   retained in turn, so recovery loses nothing. The restored image becomes
   visible wherever the avatar or logo is shown, to everyone who can see it now.

Storage: history is not counted towards any quota and is not pruned. Avatars are
under 5 MB each. Permanently erasing a person's or the site's image history is
part of the separate administrative account/user deletion process (#93):
destroying the Profile or Setting removes its history links and purges the
bytes of each image attached nowhere else. An image still attached to another
record (for example a message attachment) keeps its bytes.
