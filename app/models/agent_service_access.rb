class AgentServiceAccess < ApplicationRecord

  class SendGrantRefused < StandardError; end

  belongs_to :agent
  belongs_to :service_connection

  # Who is changing this row, when a person is (set by set_service_access!
  # and change_send_grant!). Recorded in the send grant history.
  attr_accessor :send_grant_actor

  validates :service_connection_id, uniqueness: { scope: :agent_id }
  validate :same_account
  validate :can_send_only_through_change_send_grant

  scope :enabled, -> { where(enabled: true) }
  scope :sending, -> { enabled.where(can_send: true) }

  # No revival (WhatsApp spec §5): set_service_access! reuses this row and
  # changes only `enabled`, so a disabled row loses can_send here, whoever
  # disables it. Re-enabling read never restores it.
  before_validation :withdraw_send_when_disabled
  before_save :withdraw_send_when_disabled
  after_save :record_send_withdrawal_on_disable

  # Commit callbacks are deduplicated by filter name. Keep distinct wrapper
  # methods here so create, update, and destroy reconciliation all survive.
  after_create_commit :schedule_reconciliation_after_create!
  # A send grant changes the resident's manifest (its send endpoint).
  after_update_commit :schedule_reconciliation_after_update!, if: -> { saved_change_to_enabled? || saved_change_to_can_send? }
  after_destroy_commit :schedule_reconciliation_after_destroy!

  after_save :refresh_integration_status, if: :integration_status_changed?
  after_destroy :refresh_integration_status

  INTEGRATION_STATUS_COLUMNS = %w[
    agent_id service_connection_id enabled follows_default
    provisioning_status provisioning_error_code
  ].freeze

  def schedule_reconciliation!
    return unless agent&.externally_hosted? && agent.container_name.present?

    if persisted?
      status = enabled? ? "pending" : "removal_pending"
      changed = provisioning_status != status || provisioning_error_code.present?
      written = update_columns(
        provisioning_status: status,
        provisioning_error_code: nil,
        updated_at: Time.current
      )
      refresh_integration_status if written && changed
    end
    AccountAgentCredentialsRefreshJob.perform_later(agent.account_id, agent.id, manifest_only: true)
  end

  def mark_provisioned!
    update!(
      provisioned_revision: service_connection.credential_revision,
      provisioned_at: Time.current,
      provisioning_status: "provisioned",
      provisioning_error_code: nil
    )
  end

  # Grants or withdraws sending as the connection's owner. Only the owner can
  # grant (speaking as a person is that person's grant to give): account
  # admins, freely_provisionable and enabled_for_new_agents confer nothing.
  # Anyone who can manage the connection can withdraw. Every change is
  # recorded.
  #
  # Lock order, the same everywhere a grant is set or cleared (here,
  # Agent#set_service_access!, ServiceConnection#withdraw_send_grants and
  # CommsSending): the connection's row first, then the access row. Owner,
  # status, gate and enabled are all read after both locks are held, so a
  # concurrent owner change, disconnect, re-pair or disable either commits
  # first (and this sees it) or waits for this to commit (and then
  # withdraws what this granted).
  def change_send_grant!(can_send, actor:)
    can_send = ActiveModel::Type::Boolean.new.cast(can_send)
    connection = service_connection
    connection.transaction do
      connection.lock!
      lock!
      unless connection.send_grant_changeable_by?(actor, can_send: can_send)
        raise SendGrantRefused, can_send ? "Only the connection's owner can let a resident send" : "You cannot manage this connection"
      end
      next if self.can_send == can_send

      if can_send
        raise SendGrantRefused, "Sending is not available for this connection" unless CommsSending.available_for?(connection)
        raise SendGrantRefused, "Enable this resident's access first" unless enabled?
        raise SendGrantRefused, "Reconnect this service before letting a resident send" unless connection.status == "connected"
      end
      @granting_send = can_send
      begin
        update!(can_send: can_send)
      ensure
        @granting_send = false
      end
      CommsSendGrantEvent.record!(self, granted: can_send, actor: actor, reason: can_send ? "granted" : "withdrawn")
    end
    self
  end

  private

  def withdraw_send_when_disabled
    return unless !enabled? && can_send?

    self.can_send = false
    @send_withdrawn_by_disable = persisted? && can_send_in_database
  end

  def record_send_withdrawal_on_disable
    return unless @send_withdrawn_by_disable

    @send_withdrawn_by_disable = false
    CommsSendGrantEvent.record!(self, granted: false, actor: send_grant_actor || Current.user, reason: "access_disabled")
  end

  # can_send becomes true only inside change_send_grant!, under its locks
  # and checks. Any other write that tries (a mass assignment, a default
  # access, a resident's own call) is invalid.
  def can_send_only_through_change_send_grant
    return unless can_send?

    errors.add(:can_send, "can only be granted by the connection's owner") if will_save_change_to_can_send? && !@granting_send
    errors.add(:can_send, "needs enabled access") unless enabled?
    errors.add(:can_send, "is only for comms connections") unless service_connection&.credential_strategy == "connector"
  end

  def integration_status_changed?
    previously_new_record? || (saved_changes.keys & INTEGRATION_STATUS_COLUMNS).any?
  end

  def refresh_integration_status
    agent_ids = [ agent_id, *saved_change_to_agent_id ].compact
    connection_ids = [ service_connection_id, *saved_change_to_service_connection_id ].compact
    IntegrationStatus.refresh!(
      Agent.where(id: agent_ids).pluck(:account_id) +
        ServiceConnection.where(id: connection_ids).pluck(:account_id)
    )
  end

  def schedule_reconciliation_after_create!
    schedule_reconciliation!
  end

  def schedule_reconciliation_after_update!
    schedule_reconciliation!
  end

  def schedule_reconciliation_after_destroy!
    schedule_reconciliation!
  end

  def same_account
    return unless agent && service_connection
    errors.add(:service_connection, "must belong to the resident's account") unless agent.account_id == service_connection.account_id
  end

end
