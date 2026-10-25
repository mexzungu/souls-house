require "test_helper"

# Force the request's initial check to pass, then change the stored connection
# just before the model takes its locks. Model concurrency is tested separately.
class ServiceReadGrantRaceTest < ActionDispatch::IntegrationTest

  module ChangeBeforeLock

    def set_service_access!(connection, **options)
      Thread.current[:read_grant_request_change]&.call(connection)
      super
    end

  end
  Agent.prepend(ChangeBeforeLock)

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external")
    @connection = @account.service_connections.create!(
      connected_by_user: @user, connected_by_agent: @agent,
      provider: "github", external_subject_id: "read-grant-race",
      external_identity: "owner", management_scope: "personal",
      credential_kind: "token", credential_fingerprint: "read-grant-race",
      credential_payload_hash: { "token" => "test-only" },
      credential_metadata: { "credential_strategy" => "static", "repository" => "owner/repo" }
    )
    @token = ApiKey.generate_for(@user, name: "Read grant race", account: @account).raw_token
  end

  teardown do
    Thread.current[:read_grant_request_change] = nil
  end

  test "web refuses an owner change after its initial check without success audit" do
    sign_in @user
    change_before_lock { |connection| connection.update_columns(connected_by_user_id: users(:regular_user).id) }

    assert_no_grant_or_success_audit do
      patch account_agent_service_access_path(@account, @agent, @connection.public_id), params: { enabled: true }
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "integrations")
    assert_equal "You cannot change this resident's access", flash[:alert]
  end

  test "web refuses a status change after its initial check" do
    sign_in @user
    change_before_lock { |connection| connection.update_columns(status: "reauthorizing") }

    assert_no_grant_or_success_audit do
      patch account_agent_service_access_path(@account, @agent, @connection.public_id), params: { enabled: true }
    end
    assert_equal "Reconnect this service before enabling resident access", flash[:alert]
  end

  test "human API refuses an owner change after its initial check" do
    change_before_lock { |connection| connection.update_columns(connected_by_user_id: users(:regular_user).id) }
    assert_no_grant_or_success_audit { human_request }
    assert_response :forbidden
  end

  test "human API reports conflict for a status change after its initial check" do
    change_before_lock { |connection| connection.update_columns(status: "disconnected") }
    assert_no_grant_or_success_audit { human_request }
    assert_response :conflict
  end

  test "resident API refuses lost connection provenance without posting a notice" do
    prepare_resident_request
    change_before_lock { |connection| connection.update_columns(connected_by_agent_id: nil) }
    assert_no_difference -> { @chat.messages.count } do
      assert_no_grant_or_success_audit { resident_request }
    end
    assert_response :not_found
  end

  test "resident API refuses a status change without posting a notice" do
    prepare_resident_request
    change_before_lock { |connection| connection.update_columns(status: "disconnected") }
    assert_no_difference -> { @chat.messages.count } do
      assert_no_grant_or_success_audit { resident_request }
    end
    assert_response :conflict
  end

  private

  def change_before_lock(&block)
    Thread.current[:read_grant_request_change] = ->(connection) do
      # Modify another instance, leaving the controller's connection stale.
      block.call(ServiceConnection.find(connection.id))
    end
  end

  def assert_no_grant_or_success_audit(&block)
    assert_no_difference [
      -> { AgentServiceAccess.where(service_connection: @connection).count },
      -> { AuditLog.where(action: "enable_resident_service").count }
    ], &block
  end

  def human_request
    patch service_access_api_v1_resident_url(@agent, connection_id: @connection.public_id),
          headers: { "Authorization" => "Bearer #{@token}" }, params: { enabled: true }, as: :json
  end

  def prepare_resident_request
    # Ghost, unlike OAuth providers, is in the resident-manageable lane.
    @connection.update_columns(provider: "ghost")
    @chat = @account.chats.new(title: "Read grant race", model_id: "openrouter/auto", manual_responses: true)
    @chat.agents = [ @agent ]
    @chat.save!
    @token = ApiKey.generate_for(@user, name: "Resident read grant race", agent: @agent).raw_token
  end

  def resident_request
    patch resident_access_api_v1_resident_service_connection_path(@connection.public_id, resident_id: @agent.to_param),
          headers: { "Authorization" => "Bearer #{@token}" },
          params: { enabled: true, conversation_id: @chat.to_param }, as: :json
  end

end
