require "test_helper"

class AccountDisableVmTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
  end

  test "disabling an account requests cleanup of its residents' VM servers" do
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")

    assert_enqueued_with(job: VmCleanupJob, args: [ placement.id ]) { @account.disable! }

    assert placement.reload.cleanup_requested?
    assert_equal "account_disabled", placement.cleanup_reason
  end

  test "disabling leaves retired, staged and local placements alone" do
    staged = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", kind: "archive_import", state: "staged")
    local = AgentPlacement.create!(agent: agents(:code_reviewer), backend: "local", state: "ready")

    assert_no_enqueued_jobs(only: VmCleanupJob) { @account.disable! }

    assert_not staged.reload.cleanup_requested?
    assert_not local.reload.cleanup_requested?
  end

  test "enabling an account requests nothing" do
    @account.disable!
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "pending")

    assert_no_enqueued_jobs(only: VmCleanupJob) { @account.enable! }

    assert_not placement.reload.cleanup_requested?
  end

  test "the backup sweeper skips residents of a disabled account" do
    @agent.update_columns(runtime: "external")
    Agents::Config.stub(:backups_enabled?, true) do
      assert_enqueued_with(job: Backup::AgentResticJob, args: [ @agent.id ]) { Backup::AgentBackupSweeperJob.perform_now }
      clear_enqueued_jobs
      @account.disable!
      Backup::AgentBackupSweeperJob.perform_now
      swept = enqueued_jobs.select { |job| job["job_class"] == "Backup::AgentResticJob" }.map { |job| job["arguments"].first }
      assert_not_includes swept, @agent.id
    end
  end

  test "a backup queued before the disable does not run, even forced" do
    @agent.update_columns(runtime: "external", uuid: SecureRandom.uuid)
    @account.disable!
    job = Backup::AgentResticJob.new
    job.define_singleton_method(:init_restic_repo!) { |_agent| raise "restic reached" }

    Agents::Config.stub(:backups_enabled?, true) do
      assert_nil job.perform(@agent.id)
      assert_nil job.perform(@agent.id, force: true)
    end
    assert_empty @agent.agent_backup_snapshots
  end

  test "a wake queued before the disable is cancelled at admission" do
    Setting.instance.update!(resident_turn_limit: 2)
    turn = queue_turn
    @account.disable!

    assert_empty ResidentTurn.admit!
    assert_equal "cancelled", turn.reload.state
  end

  test "a turn admitted before the disable but not yet submitted is withdrawn" do
    turn = queue_turn
    turn.update!(state: "starting", admitted_at: Time.current)
    @account.disable!

    Agents::RuntimeLocation.stub(:dispatchable?, true) { turn.withdraw_unless_deliverable! }
    assert_predicate turn.reload.cancel_requested_at, :present?
  end

  private

  def queue_turn
    session = SecureRandom.uuid
    interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: session,
      started_at: Time.current, endpoint_url: "https://runtime.example.test")
    ResidentTurn.enqueue!(interaction, { session_id: session, request: "wake" })
  end

end
