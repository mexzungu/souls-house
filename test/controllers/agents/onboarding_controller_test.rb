require "test_helper"

class Agents::OnboardingControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "provisioning", birth_committed_at: Time.current, provisioning_started_at: Time.current,
      uuid: SecureRandom.uuid_v7)
    Setting.instance.update!(allow_agents: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "a resident among others offers its settings and the list of residents" do
    get onboarding_account_agent_path(@account, @agent)

    assert_response :success
    assert_equal false, inertia_props["first_resident"]
    assert_nil inertia_props["vm_steps"], "a resident on the house's own machine has no server steps"
  end

  test "the first resident in an account is not offered settings or a list of one" do
    @account.agents.where.not(id: @agent.id).update_all(account_id: accounts(:team_account).id)

    get onboarding_account_agent_path(@account, @agent)

    assert_response :success
    assert_equal true, inertia_props["first_resident"]
  end

  private

  def inertia_props
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)["props"]
  end

end
