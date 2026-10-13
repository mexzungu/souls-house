require "test_helper"
require "support/whatsapp_comms_helpers"

class Accounts::ServiceConnectionPairingsControllerTest < ActionDispatch::IntegrationTest

  include WhatsappCommsHelpers

  setup do
    @account = accounts(:team)
    @owner = users(:admin)            # connected the WhatsApp connection
    @account_admin = users(:owner)    # account owner/admin, not the connection's owner
    @member = users(:member)
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @owner)
    @connection = @account.service_connections.create!(
      connected_by_user: @owner, provider: "whatsapp", management_scope: "personal", status: "pairing",
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload],
      pairing_qr: "2@QR-SECRET", pairing_qr_expires_at: 40.seconds.from_now
    )
  end

  test "the owner sees the current QR" do
    sign_in @owner
    get account_service_connection_pairing_path(@account, @connection.public_id)

    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "2@QR-SECRET", response.parsed_body.dig("qr", "code")
  end

  test "an account admin who is not the owner cannot see it, though they can manage the connection" do
    assert @connection.manageable_by?(@account_admin)
    sign_in @account_admin
    get account_service_connection_pairing_path(@account, @connection.public_id)

    assert_not_includes response.body, "QR-SECRET"
    assert_response :not_found
  end

  test "another member cannot see it" do
    sign_in @member
    get account_service_connection_pairing_path(@account, @connection.public_id)

    assert_not_includes response.body, "QR-SECRET"
    assert_response :not_found
  end

  test "a resident cannot see it, through this route or the connection JSON" do
    agent = @account.agents.create!(name: "Pairing Reader", model_id: "openrouter/auto")
    key = ApiKey.generate_for(@owner, name: "Resident", agent: agent)
    get account_service_connection_pairing_path(@account, @connection.public_id), headers: { "Authorization" => "Bearer #{key.raw_token}" }

    assert_not_includes response.body, "QR-SECRET"
    assert_not_equal 200, response.status
    assert_not_includes @connection.as_connection_json(current_user: @owner).to_json, "QR-SECRET"
    assert_not_includes Agents::ServiceManifest.new(agent).to_yaml, "QR-SECRET"
  end

  test "an expired QR is never served and is cleared" do
    @connection.update!(pairing_qr_expires_at: 1.second.ago)
    sign_in @owner
    get account_service_connection_pairing_path(@account, @connection.public_id)

    assert_response :ok
    assert_nil response.parsed_body["qr"]
    assert_nil @connection.reload.pairing_qr
  end

  test "the QR is cleared once connected and on disconnect" do
    @connection.update!(status: "connected", pairing_qr: nil, pairing_qr_expires_at: nil)
    sign_in @owner
    get account_service_connection_pairing_path(@account, @connection.public_id)
    assert_nil response.parsed_body["qr"]

    @connection.update!(status: "pairing", pairing_qr: "2@AGAIN", pairing_qr_expires_at: 30.seconds.from_now)
    @connection.disconnect!
    assert_nil @connection.reload.pairing_qr
    assert_nil @connection.current_pairing_qr
  end

  test "connecting WhatsApp creates a pairing connection with a secret and starts pairing" do
    started = []
    sign_in @owner
    with_connector_url do
      CommsConnector.stub(:start_pairing, ->(connection) { started << connection.id; :sent }) do
        assert_difference -> { @account.service_connections.where(provider: "whatsapp").count }, 1 do
          post account_service_connections_path(@account), params: { provider: "whatsapp", management_scope: "personal" }
        end
      end
    end

    connection = @account.service_connections.where(provider: "whatsapp").order(:id).last
    assert_equal "pairing", connection.status
    assert_equal @owner, connection.connected_by_user
    assert_match(/\A[0-9a-f]{64}\z/, connection.credential_payload_hash["callback_secret"])
    assert_equal [ connection.id ], started
  end

  test "without a configured connector, WhatsApp is neither offered nor connectable" do
    sign_in @owner
    with_whatsapp_connector(url: nil, stub_http: false) do
      assert_not Services::Definition.fetch("whatsapp").available?
      get account_integrations_path(@account)
      assert_response :success
      keys = inertia_props.dig("props", "services").map { |service| service["key"] }
      assert_includes keys, "github"
      assert_not_includes keys, "whatsapp"
      assert_no_difference -> { @account.service_connections.where(provider: "whatsapp").count } do
        post account_service_connections_path(@account), params: { provider: "whatsapp", management_scope: "personal" }
      end
    end
    with_connector_url do
      @inertia_props = nil
      get account_integrations_path(@account)
      assert_includes inertia_props.dig("props", "services").map { |service| service["key"] }, "whatsapp"
    end
  end

  # A URL alone is not enough: without the command key or any mutual-TLS
  # file, start_pairing could never be sent, so the owner is not offered a
  # connection that would only fail.
  test "WhatsApp stays hidden until the command key and mutual TLS are configured too" do
    sign_in @owner
    [ "COMMS_COMMAND_KEY", *TelegramCommsHelpers::TLS_ENV ].each do |absent|
      tls = TelegramCommsHelpers::TLS_ENV - [ absent ]
      key = absent == "COMMS_COMMAND_KEY" ? nil : "test-command-key"
      with_whatsapp_connector(key:, tls:, stub_http: false) do
        assert_not Services::Definition.fetch("whatsapp").available?, "available without #{absent}"
        @inertia_props = nil
        get account_integrations_path(@account)
        assert_not_includes inertia_props.dig("props", "services").map { |service| service["key"] }, "whatsapp"
      end
    end
  end

  test "disconnecting sends unpair and keeps a connection that has history" do
    @connection.comms_chats.create!(provider_chat_id: "c1@s.whatsapp.net")
    unpaired = []
    sign_in @owner
    CommsConnector.stub(:unpair, ->(connection) { unpaired << connection.credential_payload_hash["callback_secret"]; :sent }) do
      delete account_service_connection_path(@account, @connection.public_id)
    end

    assert_equal 1, unpaired.size
    assert unpaired.first.present?, "unpair is signed before the secret is erased"
    @connection.reload
    assert_equal "revoked", @connection.status
    assert_nil @connection.credential_payload
    assert_equal 1, @connection.comms_chats.count
  end

  test "disconnecting a connection without history destroys it" do
    sign_in @owner
    CommsConnector.stub(:unpair, :sent) do
      delete account_service_connection_path(@account, @connection.public_id)
    end
    assert_not ServiceConnection.exists?(@connection.id)
  end

  test "the owner's QR carries when it was issued, so the page never shows an older code over a newer one" do
    issued = 5.seconds.ago.change(usec: 123_000)
    @connection.update!(pairing_qr_issued_at: issued)
    sign_in @owner
    get account_service_connection_pairing_path(@account, @connection.public_id)

    assert_equal issued.utc.iso8601(3), response.parsed_body.dig("qr", "issued_at")
  end

  test "the owner restarts pairing after the codes expired: back to pairing with no code, start_pairing sent" do
    @connection.update!(pairing_qr_expires_at: 1.second.ago, pairing_qr_issued_at: 61.seconds.ago)
    started = []
    sign_in @owner
    CommsConnector.stub(:start_pairing, ->(connection) { started << connection.id; :sent }) do
      post restart_account_service_connection_pairing_path(@account, @connection.public_id)
    end

    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal({ "status" => "pairing", "qr" => nil }, response.parsed_body)
    assert_equal [ @connection.id ], started
    @connection.reload
    assert_nil @connection.pairing_qr
    assert_nil @connection.pairing_qr_issued_at
    assert AuditLog.exists?(action: "restart_service_pairing", auditable: @connection)
  end

  test "after WhatsApp logs the device out, the owner pairs again" do
    @connection.update!(status: "reauthorizing", pairing_qr: nil, pairing_qr_expires_at: nil)
    sign_in @owner
    CommsConnector.stub(:start_pairing, :sent) do
      post restart_account_service_connection_pairing_path(@account, @connection.public_id)
    end

    assert_response :ok
    assert_equal "pairing", @connection.reload.status
  end

  test "a connected connection is not restarted" do
    @connection.update!(status: "connected", pairing_qr: nil, pairing_qr_expires_at: nil)
    sign_in @owner
    CommsConnector.stub(:start_pairing, ->(_) { flunk "start_pairing sent for a connected connection" }) do
      post restart_account_service_connection_pairing_path(@account, @connection.public_id)
    end

    assert_response :conflict
    assert_equal "connected", @connection.reload.status
  end

  test "an unreachable connector is reported, not raised" do
    sign_in @owner
    CommsConnector.stub(:start_pairing, ->(_) { raise CommsConnector::Error, "down" }) do
      post restart_account_service_connection_pairing_path(@account, @connection.public_id)
    end

    assert_response :bad_gateway
    assert_match(/Could not reach the WhatsApp connector/, response.parsed_body["error"])
  end

  test "only the owner can restart pairing" do
    [ @account_admin, @member ].each do |user|
      sign_in user
      CommsConnector.stub(:start_pairing, ->(_) { flunk "start_pairing sent for #{user.email_address}" }) do
        post restart_account_service_connection_pairing_path(@account, @connection.public_id)
      end
      assert_response :not_found
      assert_not_includes response.body, "QR-SECRET"
    end
    assert_equal "2@QR-SECRET", @connection.reload.pairing_qr
  end

  private

  def with_connector_url(&block)
    with_whatsapp_connector(stub_http: false) { block.call }
  end

end
