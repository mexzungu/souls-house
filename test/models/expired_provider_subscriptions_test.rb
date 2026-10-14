require "test_helper"

class ExpiredProviderSubscriptionsTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
  end

  test "counts expired subscription logins across every confirmed account and names them" do
    expire!(agents(:code_reviewer), "anthropic")
    expire!(agents(:other_account_agent), "gemini")

    summary = ExpiredProviderSubscriptions.summary_for(@user)

    assert_equal 2, summary[:total]
    assert_equal 1, summary[:accounts][accounts(:personal_account).to_param]
    assert_equal 1, summary[:accounts][accounts(:team_account).to_param]
    item = summary[:items].find { |i| i[:agent_id] == agents(:code_reviewer).to_param }
    assert_equal "Claude", item[:provider_name]
    assert_equal "Code Reviewer", item[:agent_name]
    assert_includes item[:url], "tab=hosting"
  end

  test "connected, api-key and retired residents do not count, and reconnecting clears it" do
    agent = agents(:code_reviewer)
    agent.update!(provider_auth_modes: { "anthropic" => "oauth_account" },
                  provider_connections: { "anthropic" => { "status" => "connected" } })
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    agent.mark_provider_connection_status!("anthropic", "expired")
    assert_equal 1, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    agent.use_provider_auth_mode!("anthropic", "api_key")
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(@user)[:total]

    expire!(agent, "anthropic")
    agent.update_columns(runtime: Agent::RuntimeAvailability::RETIRED_RUNTIMES.first)
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(@user)[:total]
  end

  test "accounts the person is not a confirmed member of are not counted" do
    expire!(agents(:code_reviewer), "anthropic")
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(users(:needsreset_user))[:total]
    assert_equal 0, ExpiredProviderSubscriptions.summary_for(users(:unconfirmed_user))[:total]
  end

  private

  def expire!(agent, provider)
    agent.update_columns(
      provider_auth_modes: { provider => "oauth_account" },
      provider_connections: { provider => { "status" => "expired", "email" => "x@example.com" } }
    )
  end

end
