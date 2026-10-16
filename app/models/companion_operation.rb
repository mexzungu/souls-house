class CompanionOperation < ApplicationRecord

  include ObfuscatesId

  class Refused < StandardError; end

  READ_KINDS = %w[drives list stat search read].freeze
  ACTIVE_STATES = %w[pending dispatched].freeze
  MAX_BODY = 8.megabytes
  MAX_INLINE = 64.kilobytes
  SAFE_ERRORS = %w[denied cancelled deadline invalid unsupported unavailable changed failed].freeze

  belongs_to :companion_device
  belongs_to :agent
  has_one :body, class_name: "CompanionOperationBody", dependent: :destroy

  def self.start!(device:, agent:, kind:, arguments:)
    raise Refused, "Unsupported read operation" unless READ_KINDS.include?(kind)
    raise Refused, "Invalid arguments" unless arguments.is_a?(Hash) && arguments.to_json.bytesize <= 8.kilobytes
    raise Refused, "Unexpected arguments" unless (arguments.keys - %w[volume path offset limit pattern cursor]).empty?

    device.with_lock do
      where(companion_device: device, state: ACTIVE_STATES).where(deadline: ..Time.current).update_all(state: "timed_out", outcome: "deadline")
      raise Refused, "Device unavailable" unless device.revoked_at.nil? && !device.paused? && device.connection_epoch.present?
      raise Refused, "Grant denied" unless permitted?(device, agent, kind, arguments)
      raise Refused, "Device busy" if where(companion_device: device, state: ACTIVE_STATES).count >= 4

      create!(companion_device: device, agent: agent, kind: kind, arguments: arguments,
        connection_epoch: device.connection_epoch, grant_revision: device.grant_revision, deadline: 30.seconds.from_now)
    end
  end

  def self.permitted?(device, agent, kind, arguments)
    return false if device.account.reload.disabled? || agent.account_id != device.account_id || !agent.reload.active?

    resident = device.policy.fetch("residents", []).find { |r| r["id"] == agent.obfuscated_id }
    return false unless resident
    return true if kind == "drives"

    resident.fetch("volumes", []).any? { |g| g["volume"] == arguments["volume"] && %w[read write].include?(g["access"]) }
  end

  # The row exists before any broadcast. Reconnect never replays it.
  def dispatch!
    companion_device.with_lock do
      with_lock do
        return false unless state == "pending" && deliverable?

        update!(state: "dispatched")
        CompanionChannel.broadcast_to(companion_device, envelope)
        true
      end
    end
  end

  def envelope
    { type: "request", request_id: obfuscated_id, device_id: companion_device.obfuscated_id,
      resident_id: agent.obfuscated_id, grant_revision: grant_revision, connection_epoch: connection_epoch,
      deadline: deadline.iso8601(6), operation: kind, arguments: arguments, policy: companion_device.policy }
  end

  def deliverable?
    device = companion_device
    device.revoked_at.nil? && !device.paused? && device.connection_epoch == connection_epoch &&
      device.grant_revision == grant_revision && deadline.future? &&
      self.class.permitted?(device, agent, kind, arguments)
  end

  # Both dispatch and delivery hold the device lock before the operation lock.
  # Contents live separately and expire, while the safe operation audit remains.
  def complete!(epoch:, revision:, data: nil, content_type: "application/json", error: nil)
    companion_device.with_lock do
      with_lock do
        return false unless state == "dispatched"
        unless epoch == connection_epoch && revision == grant_revision && deliverable?
          update!(state: "cancelled", outcome: "changed")
          return false
        end
        if error
          update!(state: "failed", outcome: SAFE_ERRORS.include?(error) ? error : "failed")
        else
          raise Refused, "Result too large" unless data.is_a?(String) && data.bytesize <= MAX_BODY
          raise Refused, "Invalid content type" unless %w[application/json application/octet-stream].include?(content_type)
          create_body!(data: data.b, content_type: content_type, expires_at: 10.minutes.from_now)
          update!(state: "completed", outcome: "ok")
          CompanionBodyExpiryJob.set(wait: 10.minutes).perform_later(body.id)
        end
        true
      end
    end
  end

  def take_body!
    companion_device.with_lock do
      with_lock do
        unless state == "completed" && deliverable?
          body&.destroy!
          return
        end
        saved = body
        return unless saved
        data = saved.expires_at.future? ? [ saved.data, saved.content_type ] : nil
        saved.destroy!
        data
      end
    end
  end

end
