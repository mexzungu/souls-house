# Retries every WhatsApp disconnect the connector has not confirmed
# (ServiceConnection#unpair_pending?), until it does. Recurring; see
# config/recurring.yml. A connector that is not configured at all counts
# as confirmed: there is no connector holding a device.
class CommsUnpairJob < ApplicationJob

  queue_as :default

  def perform
    ServiceConnection.where(provider: "whatsapp", status: "revoked")
                     .where("connector_state -> 'unpair' IS NOT NULL")
                     .find_each(&:retry_unpair!)
  end

end
