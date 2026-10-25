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

end
