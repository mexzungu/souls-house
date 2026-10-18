require "test_helper"
require "timeout"

class AbandonedAppUploadsJobTest < ActiveSupport::TestCase

  # These tests exercise actual commits and independent PostgreSQL row locks.
  self.use_transactional_tests = false

  setup do
    @user = users(:user_1)
    @chat = accounts(:personal_account).chats.create!(
      title: "Upload cleanup", model_id: "openrouter/auto", manual_responses: false
    )
    @blobs = []
    @now = Time.current.change(usec: 0)
  end

  teardown do
    @chat.destroy!
    @blobs.each { |blob| ActiveStorage::Blob.find_by(id: blob.id)&.purge }
  end

  test "only tagged unattached uploads strictly older than a day are removed" do
    stale = upload(created_at: @now - 24.hours - 1.second)
    boundary = upload(created_at: @now - 24.hours)
    recent = upload(created_at: @now - 1.hour)
    untagged = upload(created_at: @now - 2.days, metadata: {})
    nested = upload(created_at: @now - 2.days, metadata: { "other" => { "app_upload" => {} } })
    attached = upload(created_at: @now - 2.days)
    message = send_upload(attached).message
    message.discard!

    AbandonedAppUploadsJob.perform_now(now: @now)

    assert_not ActiveStorage::Blob.exists?(stale.id)
    assert_not stale.service.exist?(stale.key)
    [ boundary, recent, untagged, nested, attached ].each do |blob|
      assert ActiveStorage::Blob.exists?(blob.id)
      assert blob.service.exist?(blob.key)
    end
    assert message.reload.attachments.attached?
  end

  test "a bounded batch is removed and another run takes the remainder" do
    blobs = 3.times.map { upload(created_at: @now - 2.days) }
    stub_const(AbandonedAppUploadsJob, :BATCH_SIZE, 2) do
      AbandonedAppUploadsJob.perform_now(now: @now)
      assert_equal 1, ActiveStorage::Blob.where(id: blobs.map(&:id)).count
      AbandonedAppUploadsJob.perform_now(now: @now)
    end
    assert_empty ActiveStorage::Blob.where(id: blobs.map(&:id))
  end

  test "a storage deletion failure cannot resurrect the row or damage a neighboring upload" do
    blob = upload(created_at: @now - 2.days)
    neighbor = upload(created_at: @now - 2.days)
    service = blob.service
    service.stub(:delete, ->(*) { raise IOError, "storage unavailable" }) do
      assert_raises(IOError) { AbandonedAppUploadsJob.perform_now(now: @now) }
    end

    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert service.exist?(blob.key)
    assert ActiveStorage::Blob.exists?(neighbor.id)
    assert service.exist?(neighbor.key)
    AbandonedAppUploadsJob.perform_now(now: @now)
    assert_not ActiveStorage::Blob.exists?(neighbor.id)
  ensure
    service&.delete(blob.key) if blob
  end

  test "nested metadata keys cannot fill the batch and starve real abandoned uploads" do
    nested = 2.times.map do
      upload(created_at: @now - 2.days, metadata: { "other" => { "app_upload" => {} } })
    end
    abandoned = upload(created_at: @now - 2.days)

    stub_const(AbandonedAppUploadsJob, :BATCH_SIZE, 2) do
      AbandonedAppUploadsJob.perform_now(now: @now)
    end

    assert_not ActiveStorage::Blob.exists?(abandoned.id)
    nested.each do |blob|
      assert ActiveStorage::Blob.exists?(blob.id)
      assert blob.service.exist?(blob.key)
    end
  end

  test "a claim holding the blob lock is skipped and its committed attachment survives" do
    blob = upload(created_at: @now - 2.days)
    locked, release = Queue.new, Queue.new
    claimant = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        send_upload(blob, on_persisted: ->(*) { locked << true; release.pop })
      end
    end

    Timeout.timeout(10) do
      locked.pop
      AbandonedAppUploadsJob.perform_now(now: @now)
      assert ActiveStorage::Blob.exists?(blob.id)
      release << true
      assert claimant.value.created?
    end
    AbandonedAppUploadsJob.perform_now(now: @now)
    assert ActiveStorage::Attachment.exists?(blob_id: blob.id)
    assert blob.service.exist?(blob.key)
  ensure
    release << true if release
    claimant&.join(10)
  end

  test "cleanup commits before file deletion and a previously resolved claim then refuses" do
    blob = upload(created_at: @now - 2.days)
    deleting, release = Queue.new, Queue.new
    service = blob.service
    original_delete = service.method(:delete)
    service.stub(:delete, lambda { |key|
      deleting << true
      release.pop
      original_delete.call(key)
    }) do
      cleaner = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          AbandonedAppUploadsJob.perform_now(now: @now)
        end
      end

      Timeout.timeout(10) do
        deleting.pop
        assert_not ActiveStorage::Blob.exists?(blob.id)
        assert service.exist?(blob.key), "bytes are removed only after commit"
        assert_no_difference "Message.count" do
          assert send_upload(blob).attachment_claimed?
        end
        release << true
        cleaner.value
      end
    ensure
      release << true
      cleaner&.join(10)
    end
    assert_not service.exist?(blob.key)
    assert_not ActiveStorage::Attachment.exists?(blob_id: blob.id)
  end

  private

  def stub_const(klass, name, value)
    original = klass.const_get(name)
    klass.send(:remove_const, name)
    klass.const_set(name, value)
    yield
  ensure
    klass.send(:remove_const, name)
    klass.const_set(name, original)
  end

  def upload(created_at:, metadata: nil)
    metadata ||= { "app_upload" => { "user_id" => @user.id, "chat_id" => @chat.id } }
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("orphan upload"), filename: "upload.txt", content_type: "text/plain", metadata: metadata
    )
    @blobs << blob
    blob.update_columns(created_at: created_at)
    blob
  end

  def send_upload(blob, on_persisted: nil)
    Messages::PostFromHuman.new(
      chat: @chat, user: @user, content: "Upload #{SecureRandom.hex(4)}",
      files: [ blob ], client_message_id: SecureRandom.uuid
    ).call(on_persisted: on_persisted)
  end

end
