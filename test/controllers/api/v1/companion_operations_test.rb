require "test_helper"

class Api::V1::CompanionOperationsTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @key = ApiKey.generate_for(users(:user_1), name: "Fixture", agent: @agent)
    grant = CompanionEnrollmentGrant.create!(account: @agent.account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Fixture", device_request_id: "fixture",
      policy: { "residents" => [ { "id" => @agent.obfuscated_id,
        "volumes" => [ { "volume" => "fixture-volume", "access" => "read" } ], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "fixture")
    @device.update!(connection_epoch: "epoch")
  end

  test "resident dispatches read and device-only HTTP body returns to its originating actor" do
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "read", arguments: { volume: "fixture-volume", path: "fixture" } },
      headers: bearer(@key.raw_token), as: :json
    assert_response :accepted
    id = response.parsed_body.fetch("id")
    post "/api/v1/companion/operations/#{id}/result", params: "fixture bytes",
      headers: bearer(@credential).merge("CONTENT_TYPE" => "application/octet-stream",
        "X-Companion-Epoch" => "epoch", "X-Companion-Revision" => "1", "X-Companion-Format" => "binary")
    assert_response :created
    get "/api/v1/companion_devices/#{@device.to_param}/operations/#{id}/body", headers: bearer(@key.raw_token)
    assert_response :success
    assert_equal "fixture bytes", response.body
    get "/api/v1/companion_devices/#{@device.to_param}/operations/#{id}/body", headers: bearer(@key.raw_token)
    assert_response :gone
  end

  test "device credential cannot call resident APIs and resident bearer cannot upload device results" do
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "drives", arguments: {} }, headers: bearer(@credential), as: :json
    assert_response :unauthorized
    post "/api/v1/companion/operations/not-an-id/result", params: "fixture",
      headers: bearer(@key.raw_token).merge("CONTENT_TYPE" => "application/octet-stream")
    assert_response :unauthorized
  end

  test "missing arguments is valid for discovery but scalar arguments is rejected" do
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "drives" }, headers: bearer(@key.raw_token), as: :json
    assert_response :accepted
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "read", arguments: "not-an-object" }, headers: bearer(@key.raw_token), as: :json
    assert_response :unprocessable_entity
  end

  test "human owner can pause resume and revoke but resident cannot control the device" do
    path = "/api/v1/companion_devices/#{@device.to_param}"
    patch path, params: { account_id: @agent.account.to_param, control: "pause" },
      headers: bearer(@key.raw_token), as: :json
    assert_response :forbidden
    human = ApiKey.generate_for(users(:user_1), name: "Fixture owner", account: @agent.account)
    %w[pause resume revoke].each do |control|
      patch path, params: { account_id: @agent.account.to_param, control: control },
        headers: bearer(human.raw_token), as: :json
      assert_response :no_content
      @device.reload
      assert_equal control == "pause", @device.paused? unless control == "revoke"
    end
    assert @device.revoked_at
    assert_nil CompanionDevice.authenticate(@credential)
  end

  private

  def bearer(value)
    { "Authorization" => "Bearer #{value}" }
  end

end
