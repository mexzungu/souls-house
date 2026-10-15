require "test_helper"
require "support/vcr_setup"
require "webmock/minitest"

class XIntegrationTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:team_account)
  end

  test "validates uniqueness of account" do
    XIntegration.create!(account: @account, access_token: "t", refresh_token: "rt", token_expires_at: 1.day.from_now)

    duplicate = XIntegration.new(account: @account, access_token: "t2", refresh_token: "rt2")
    assert_not duplicate.valid?
  end

  test "connected? requires access_token and refresh_token" do
    integration = XIntegration.new(account: @account)
    assert_not integration.connected?

    integration.assign_attributes(access_token: "t", refresh_token: "rt")
    assert integration.connected?
  end

  test "disconnect! clears all credentials" do
    integration = XIntegration.create!(
      account: @account,
      access_token: "t", refresh_token: "rt",
      token_expires_at: 1.day.from_now,
      x_username: "bot"
    )

    integration.disconnect!
    integration.reload

    assert_nil integration.access_token
    assert_nil integration.refresh_token
    assert_nil integration.token_expires_at
    assert_nil integration.x_username
    assert_not integration.connected?
  end

  test "enabled scope returns only enabled integrations" do
    XIntegration.create!(account: @account, enabled: true, access_token: "t", refresh_token: "rt")

    assert_equal 1, XIntegration.enabled.count
  end

  test "token_fresh? returns false when expired" do
    integration = XIntegration.new(token_expires_at: 1.minute.from_now)
    assert_not integration.token_fresh?
  end

  test "token_fresh? returns true when well before expiry" do
    integration = XIntegration.new(token_expires_at: 1.hour.from_now)
    assert integration.token_fresh?
  end

  test "an account without a site admin has no X app until it enters its own, and never uses the house app" do
    integration = XIntegration.create!(account: @account)

    with_house_x_app do
      assert_not integration.house_app_allowed?
      assert_nil integration.app_source

      integration.set_own_app!(client_id: " own-cid ", client_secret: "own-secret")
      assert_equal "own", integration.reload.app_source
      assert_equal "own-cid", integration.client_id
    end
  end

  test "an account with a confirmed site admin uses the house app, and its own app when it has one" do
    @account.memberships.create!(user: users(:site_admin_user), role: "member", confirmed_at: Time.current)
    integration = XIntegration.create!(account: @account.reload)

    assert_nil integration.app_source, "no house app configured"
    with_house_x_app do
      assert_equal "house", integration.app_source
      integration.set_own_app!(client_id: "own-cid", client_secret: "own-secret")
      assert_equal "own", integration.app_source
    end
  end

  test "an unconfirmed site admin does not open the house app" do
    @account.memberships.create!(user: users(:site_admin_user), role: "member", confirmed_at: nil)
    integration = XIntegration.create!(account: @account.reload)

    with_house_x_app { assert_nil integration.app_source }
  end

  test "the client secret is encrypted at rest" do
    integration = XIntegration.create!(account: @account, client_id: "cid", client_secret: "very-secret")

    raw = XIntegration.connection.select_value("SELECT client_secret FROM x_integrations WHERE id = #{integration.id}")
    assert_not_includes raw, "very-secret"
    assert_equal "very-secret", integration.reload.client_secret
  end

  test "changing or removing the own app disconnects the handle and switches posting off" do
    integration = XIntegration.create!(account: @account, enabled: true, client_id: "cid", client_secret: "sec",
      access_token: "t", refresh_token: "rt", token_expires_at: 1.hour.from_now, x_username: "bot")

    integration.set_own_app!(client_id: "cid", client_secret: "sec")
    assert integration.reload.connected?, "saving the same app changes nothing"

    integration.set_own_app!(client_id: "cid2", client_secret: "sec2")
    integration.reload
    assert_not integration.connected?
    assert_not integration.enabled?
    assert_nil integration.x_username

    integration.update!(access_token: "t", refresh_token: "rt", enabled: true)
    integration.remove_own_app!
    integration.reload
    assert_not integration.connected?
    assert_not integration.enabled?
    assert_not integration.own_app?
  end

  test "both halves of the own app are required" do
    integration = XIntegration.create!(account: @account)

    assert_raises(ArgumentError) { integration.set_own_app!(client_id: "cid", client_secret: " ") }
    assert_not integration.reload.own_app?
  end

  test "token refresh authenticates as the account's own app" do
    integration = XIntegration.create!(account: @account, client_id: "own-cid", client_secret: "own-secret",
      access_token: "old", refresh_token: "rt", token_expires_at: 1.minute.ago)
    stub = stub_request(:post, "https://api.x.com/2/oauth2/token")
      .with(headers: { "Authorization" => "Basic #{Base64.strict_encode64("own-cid:own-secret")}" })
      .to_return(status: 200, body: { access_token: "new", refresh_token: "rt2", expires_in: 7200 }.to_json)

    with_house_x_app { integration.refresh_tokens! }

    assert_requested stub, times: 1
    assert_equal "new", integration.reload.access_token
  end

  test "without an app, refreshing fails without calling X" do
    integration = XIntegration.create!(account: @account, access_token: "old", refresh_token: "rt", token_expires_at: 1.minute.ago)

    with_house_x_app do
      assert_raises(XApi::Error) { integration.refresh_tokens! }
    end
    assert_not_requested :post, "https://api.x.com/2/oauth2/token"
  end

  private

  def with_house_x_app(&block)
    credentials = Rails.application.credentials
    original = credentials.method(:dig)
    credentials.stub(:dig, ->(*keys) { keys.first == :x ? { client_id: "house-cid", client_secret: "house-secret" }[keys.last] : original.call(*keys) }, &block)
  end

end
