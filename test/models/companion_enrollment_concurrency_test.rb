require "test_helper"

class CompanionEnrollmentConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    agent = agents(:research_assistant)
    @grant = CompanionEnrollmentGrant.create!(account: accounts(:personal_account), minting_agent: agent,
      created_by_user: users(:user_1), name: "Concurrency fixture", device_request_id: "concurrent-request",
      policy: { "residents" => [ { "id" => agent.obfuscated_id, "volumes" => [], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @token = @grant.issue_token!(agent)
    @ready = Queue.new
    @release = Queue.new
  end

  teardown do
    @release.push(true)
    @threads&.each { |thread| thread.join(5) }
    devices = CompanionDevice.where(companion_enrollment_grant: @grant)
    AuditLog.where(auditable_type: "CompanionDevice", auditable_id: devices.select(:id)).delete_all
    CompanionCableTicket.where(companion_device_id: devices.select(:id)).delete_all
    devices.delete_all
    @grant.delete
  end

  test "simultaneous consumers create exactly one device" do
    first = in_thread do
      CompanionEnrollmentGrant.transaction do
        CompanionEnrollmentGrant.enroll!(@token, "concurrent-request").tap { @ready.push(true); @release.pop }
      end
    end
    @ready.pop(timeout: 5) or flunk "first enrollment never ran"
    second = in_thread { CompanionEnrollmentGrant.enroll!(@token, "concurrent-request") }
    wait_until_blocked
    @release.push(true)
    assert first.value
    assert_equal first.value.map { |v| v.is_a?(CompanionDevice) ? v.id : v },
      second.value.map { |v| v.is_a?(CompanionDevice) ? v.id : v }
    assert_equal 1, CompanionDevice.where(companion_enrollment_grant: @grant).count
  end

  test "concurrent exact session retry rotates once and returns the same response" do
    device, credential = CompanionEnrollmentGrant.enroll!(@token, "concurrent-request")
    first = in_thread do
      CompanionDevice.transaction do
        CompanionDevice.create_session!(credential, "session-request").tap { @ready.push(true); @release.pop }
      end
    end
    @ready.pop(timeout: 5) or flunk "first session never ran"
    second = in_thread { CompanionDevice.create_session!(credential, "session-request") }
    wait_until_blocked
    @release.push(true)
    assert_equal first.value, second.value
    assert_equal 1, device.companion_cable_tickets.count
  end

  test "simultaneous ticket redemptions return exactly one device" do
    device, = CompanionEnrollmentGrant.enroll!(@token, "concurrent-request")
    value, = CompanionCableTicket.issue!(device)
    first = in_thread do
      CompanionDevice.transaction do
        CompanionCableTicket.redeem(value).tap { @ready.push(true); @release.pop }
      end
    end
    @ready.pop(timeout: 5) or flunk "first redemption never ran"
    second = in_thread { CompanionCableTicket.redeem(value) }
    wait_until_blocked
    @release.push(true)
    assert_equal device.id, first.value&.id
    assert_nil second.value
  end

  test "ticket redemption waits for concurrent revocation then refuses it" do
    device, = CompanionEnrollmentGrant.enroll!(@token, "concurrent-request")
    value, = CompanionCableTicket.issue!(device)
    revoker = in_thread do
      CompanionDevice.transaction do
        CompanionDevice.find(device.obfuscated_id).revoke!
        @ready.push(true)
        @release.pop
      end
    end
    @ready.pop(timeout: 5) or flunk "revocation never ran"
    redeemer = in_thread { CompanionCableTicket.redeem(value) }
    wait_until_blocked
    @release.push(true)
    revoker.value
    assert_nil redeemer.value
  end

  private

  def in_thread(&block)
    thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
    (@threads ||= []) << thread
    thread
  end

  def wait_until_blocked
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until ActiveRecord::Base.uncached {
      ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype IN ('transactionid', 'tuple')"
      ).to_i.positive?
    }
      flunk "timed out waiting for row contention" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
  end

end
