# What residents sent through a comms connection as its owner, and who was
# allowed to, as JSON for the owner (WhatsApp spec §5). Every send is
# listed, failed and unknown ones included: which resident, to whom, when,
# the text and the outcome. Only the owner sees this: not account admins
# (who can still withdraw grants and disconnect), other members, or
# residents (whose keys do not open web routes).
#
# Both lists are newest first, LIMIT at a time, each with its own cursor:
# sends_next_cursor pages the sends by (requested_at, id) and
# grant_history_next_cursor the grant history by (created_at, id), passed
# back as sends_before / grants_before. A cursor is present when a full page
# came back and null when the list is exhausted; ties on time are broken by
# id, so nothing is skipped or repeated. A malformed cursor is 400.
class Accounts::ServiceConnectionSendsController < ApplicationController

  LIMIT = 200

  def show
    connection = current_account.service_connections.find_by_public_id!(params[:service_connection_id])
    raise ActiveRecord::RecordNotFound unless connection.owner?(Current.user) && connection.credential_strategy == "connector"

    cursors = %i[sends_before grants_before].index_with { |name| params[name].presence && decode_cursor(params[name]) }
    if %i[sends_before grants_before].any? { |name| params[name].present? && cursors[name].nil? }
      return render json: { error: "sends_before and grants_before must be next_cursor values" }, status: :bad_request
    end

    sends = page(connection.comms_sends.includes(:agent, :comms_chat), :requested_at, cursors[:sends_before])
    grants = page(connection.comms_send_grant_events.includes(:agent, :actor_user), :created_at, cursors[:grants_before])

    response.headers["Cache-Control"] = "no-store"
    render json: {
      service_connection_id: connection.public_id,
      senders: connection.agent_service_accesses.sending.includes(:agent).map { |access| { resident_id: access.agent.to_param, resident_name: access.agent.name } },
      sends: sends.map(&:as_owner_json),
      sends_next_cursor: next_cursor(sends, :requested_at),
      grant_history: grants.map(&:as_owner_json),
      grant_history_next_cursor: next_cursor(grants, :created_at)
    }
  end

  private

  def page(scope, column, cursor)
    table = scope.klass.quoted_table_name
    if cursor
      at, id = cursor
      scope = scope.where("(#{table}.#{column}, #{table}.id) < (?, ?)", at, id)
    end
    scope.order(column => :desc, id: :desc).limit(LIMIT).to_a
  end

  def next_cursor(records, column)
    return unless records.size == LIMIT

    last = records.last
    Base64.urlsafe_encode64("#{last.public_send(column).utc.iso8601(6)}|#{last.id}", padding: false)
  end

  def decode_cursor(value)
    at, id = Base64.urlsafe_decode64(value.to_s).split("|", 2)
    return unless id.to_s.match?(/\A\d+\z/)

    [ Time.iso8601(at.to_s), id.to_i ]
  rescue ArgumentError
    nil
  end

end
