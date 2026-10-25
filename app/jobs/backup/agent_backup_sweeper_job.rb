module Backup
  class AgentBackupSweeperJob < ApplicationJob

    queue_as :default

    def perform
      return unless Agents::Config.backups_enabled?

      # A disabled account's servers are being deleted; nothing to back up.
      Agent.where(runtime: "external", account_id: Account.enabled.select(:id)).find_each do |agent|
        next if VmResident.held?(agent)
        next unless due?(agent)
        Backup::AgentResticJob.perform_later(agent.id)
      end
    end

    private

    def due?(agent)
      last = agent.agent_backup_snapshots.where(ok: true).order(taken_at: :desc).first
      last.nil? || last.taken_at <= agent.backup_interval_hours.hours.ago
    end

  end
end
