# Sending through a comms connection, as its owner (WhatsApp spec §5).
# Provider-neutral: WhatsApp dispatches first; Telegram plugs into the same
# tables (proposal 2026-10-11 §8).
#
# - agent_service_accesses.can_send: the owner's separate grant. Reading
#   never implies it; it defaults to false.
# - comms_sends: every send, written before the connector is called.
# - comms_messages.comms_send_id: attribution of the echoed message to its
#   send, set by whichever of the echo and the acknowledgement arrives
#   second. Never part of the message body.
# - comms_send_grant_events: every grant and withdrawal (who, when, which
#   resident, why), for the owner.
class CreateCommsSends < ActiveRecord::Migration[8.1]

  def change
    add_column :agent_service_accesses, :can_send, :boolean, default: false, null: false

    create_table :comms_sends do |t|
      t.references :service_connection, null: false, foreign_key: true, index: false
      t.references :agent, null: false, foreign_key: true
      t.references :comms_chat, null: false, foreign_key: true
      t.text :text, null: false
      t.string :client_request_id, null: false
      t.string :status, null: false, default: "pending"
      # Chosen by Rails at claim time (the provider's own format) and handed
      # to the connector, so an echo can be linked before the acknowledgement.
      t.string :provider_message_id, null: false
      # The connection's session generation at claim (WhatsApp: the pairing
      # attempt); dispatch refuses a send from another one.
      t.bigint :connection_generation, null: false
      t.string :error_code
      t.string :error_reason
      t.datetime :requested_at, null: false
      # When the send left pending for the connector. Pacing counts this.
      t.datetime :dispatched_at
      t.datetime :sent_at
      t.timestamps
      t.index %i[service_connection_id agent_id client_request_id], unique: true, name: "index_comms_sends_on_claim"
      t.index %i[service_connection_id provider_message_id], unique: true, name: "index_comms_sends_on_provider_message_id"
      t.index %i[service_connection_id dispatched_at], name: "index_comms_sends_on_connection_and_dispatched_at"
      t.index %i[service_connection_id status requested_at], name: "index_comms_sends_on_connection_status_requested_at"
      t.index %i[service_connection_id requested_at id], name: "index_comms_sends_on_connection_and_requested_at"
    end

    add_reference :comms_messages, :comms_send, foreign_key: true, index: { unique: true }, null: true

    create_table :comms_send_grant_events do |t|
      t.references :service_connection, null: false, foreign_key: true, index: false
      t.references :agent, null: false, foreign_key: true
      # Nil when the house withdrew the grant itself (disconnect, re-pair,
      # owner change).
      t.references :actor_user, foreign_key: { to_table: :users }, null: true
      t.string :action, null: false
      t.string :reason, null: false
      t.datetime :created_at, null: false
      t.index %i[service_connection_id created_at id], name: "index_comms_send_grant_events_on_connection_and_time"
    end
  end

end
