require "test_helper"
require "support/comms_send_helpers"

# #529: a request's successful precheck is not authority to write later.
# Use committed, synthetic rows and separate database connections; the change
# holds the connection lock until the stale request reaches lock acquisition.
# No sleeps, provider adapters, resident credentials, or live services.
class ServiceReadGrantConcurrencyTest < ActiveSupport::TestCase

  include CommsSendHelpers

  self.use_transactional_tests = false

  WAIT = 5

  # Only the request thread installs this hook. Observe the existing lock
  # boundary without replacing the database's real lock implementation.
  module ObserveConnectionLock

    def lock!(*args, **options)
      Thread.current[:service_read_grant_before_connection_lock]&.call(self)
      super
    end

  end
  ServiceConnection.prepend(ObserveConnectionLock)

  setup do
    @threads = []
    @releases = []
    @account = accounts(:team)
    @owner = users(:member)
    @account_admin = users(:owner)
    @agent = @account.agents.create!(
      name: "Read grant concurrency resident", model_id: "openrouter/auto", runtime: "external"
    )
    @connection = @account.service_connections.create!(
      connected_by_user: @owner,
      connected_by_agent: @agent,
      provider: "ghost",
      management_scope: "personal",
      status: "connected",
      freely_provisionable: false,
      enabled_for_new_agents: false,
      credential_kind: "token",
      credential_fingerprint: "read-grant-test-#{SecureRandom.hex(16)}",
      credential_payload_hash: { "admin_api_key" => "synthetic-read-grant-test-key" }
    )
  end

  teardown do
    # Also release/join workers if an assertion failed before the normal
    # release, so cleanup never races an outstanding database write.
    @releases.each(&:count_down)
    @threads.each do |thread|
      unless thread.join(WAIT * 2)
        thread.kill
        thread.join
      end
    end
    AgentServiceAccess.where(service_connection_id: @connection.id).delete_all if @connection
    ServiceConnection.where(id: @connection.id).delete_all if @connection
    @agent&.destroy!
  end

  [ :disabled, :absent ].each do |initial_access|
    test "owner change before enabling #{initial_access} access refuses the stale owner" do
      prepare_access(initial_access)

      assert_stale_change_refused(enabled: true, status: :forbidden) do |connection|
        connection.update!(connected_by_user: @account_admin)
      end
    end

    test "disconnect before enabling #{initial_access} access refuses the stale connected status" do
      prepare_access(initial_access)

      assert_stale_change_refused(enabled: true, status: :conflict) do |connection|
        connection.disconnect!(revoke_provider: false)
      end
      assert_equal "revoked", @connection.reload.status
    end

    test "resident scope loss before enabling #{initial_access} access hides the connection" do
      prepare_access(initial_access)

      assert_stale_change_refused(enabled: true, resident_actor: @agent,
                                 error_class: ActiveRecord::RecordNotFound) do |connection|
        connection.update!(connected_by_agent: nil)
      end
    end

    test "owner can enable #{initial_access} access when authority remains current" do
      prepare_access(initial_access)

      access = assert_thread_ok(start_thread do
        Agent.find(@agent.id).set_service_access!(
          ServiceConnection.find(@connection.id), enabled: true, actor: @owner, resident_actor: @agent
        )
      end)

      assert access.reload.enabled?
      assert_not access.can_send?
      assert_not access.follows_default?
      assert_equal 1, accesses.count
    end
  end

  test "owner change before withdrawing enabled access refuses the stale non-admin owner" do
    prepare_access(:enabled)

    assert_stale_change_refused(enabled: false, status: :forbidden) do |connection|
      connection.update!(connected_by_user: @account_admin)
    end
    assert accesses.sole.enabled?
  end

  test "resident scope loss before withdrawing enabled access hides the connection" do
    prepare_access(:enabled)

    assert_stale_change_refused(enabled: false, resident_actor: @agent,
                               error_class: ActiveRecord::RecordNotFound) do |connection|
      connection.update!(connected_by_agent: nil)
    end
    assert accesses.sole.enabled?
  end

  test "account admin can withdraw access after a concurrent disconnect" do
    prepare_access(:enabled)
    stale_connection = ServiceConnection.find(@connection.id)
    assert_not stale_connection.resident_access_changeable_by?(@account_admin, enabled: true)
    assert stale_connection.resident_access_changeable_by?(@account_admin, enabled: false)
    assert_equal "connected", stale_connection.status

    changer, request = race_after_precheck(stale_connection,
                                         change: ->(connection) { connection.disconnect!(revoke_provider: false) }) do
      Agent.find(@agent.id).set_service_access!(stale_connection, enabled: false, actor: @account_admin)
    end

    assert_equal :changed, assert_thread_ok(changer)
    access = assert_thread_ok(request)
    assert_not access.reload.enabled?
    assert_not access.can_send?
    assert_not access.follows_default?
    assert_equal "removal_pending", access.provisioning_status
    assert_equal "revoked", @connection.reload.status
  end

  private

  def accesses
    AgentServiceAccess.where(agent_id: @agent.id, service_connection_id: @connection.id)
  end

  def prepare_access(state)
    return if state == :absent

    @agent.agent_service_accesses.create!(
      service_connection: @connection, enabled: state == :enabled,
      follows_default: true, provisioning_status: "provisioned"
    )
  end

  def access_snapshot
    accesses.order(:id).pluck(:id, :enabled, :can_send, :follows_default, :provisioning_status)
  end

  def assert_stale_change_refused(enabled:, status: nil, resident_actor: nil,
                                 error_class: AgentServiceAccess::ReadGrantRefused, &change)
    stale_connection = ServiceConnection.find(@connection.id)
    # Model the checks that already passed in the controller, before its
    # request waited for the connection lock.
    assert stale_connection.resident_access_changeable_by?(@owner, enabled: enabled)
    assert_equal "connected", stale_connection.status
    assert stale_connection.resident_managed_by?(resident_actor) if resident_actor
    before = access_snapshot

    changer, request = race_after_precheck(stale_connection, change: change) do
      Agent.find(@agent.id).set_service_access!(
        stale_connection, enabled: enabled, actor: @owner, resident_actor: resident_actor
      )
    end

    assert_equal :changed, assert_thread_ok(changer)
    refusal = assert_thread_raised(request, error_class)
    assert_equal status, refusal.status if status
    assert_equal before, access_snapshot, "refusal must neither create nor mutate the access row"
  end

  def race_after_precheck(stale_connection, change:)
    changed = Concurrent::CountDownLatch.new(1)
    attempted = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)
    @releases << release

    changer = start_thread do
      connection = ServiceConnection.find(@connection.id)
      connection.with_lock do
        change.call(connection)
        changed.count_down
        raise "timed out waiting to release authority change" unless release.wait(WAIT)

        :changed
      end
    end
    assert changed.wait(WAIT), "authority change did not acquire its lock"

    request = start_thread do
      Thread.current[:service_read_grant_before_connection_lock] = lambda do |connection|
        attempted.count_down if connection.id == stale_connection.id
      end
      begin
        yield
      ensure
        Thread.current[:service_read_grant_before_connection_lock] = nil
      end
    end
    assert attempted.wait(WAIT), "stale request did not reach connection lock acquisition"
    release.count_down
    [ changer, request ]
  end

  def start_thread(&block)
    in_thread(&block).tap { |thread| @threads << thread }
  end

end
