require "test_helper"

class Agent::SubagentsTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.account.assign_attributes(use_system_ai_credentials: false)
    Account::AI_PROVIDERS.each_key { |provider| @agent.account.public_send("#{provider}_api_key=", nil) }
    @agent.account.save!
    @agent.provider_auth_modes = {}
  end

  test "subagents are disabled with an empty model list by default" do
    agent = Agent.new
    assert_not agent.subagents_enabled?
    assert_equal [], agent.subagent_models
  end

  test "normalisation strips whitespace, drops blanks, and dedupes" do
    @agent.subagent_models = [
      " openrouter:deepseek/deepseek-v4-pro-0813 ",
      "",
      "   ",
      "openrouter:deepseek/deepseek-v4-pro-0813",
      nil
    ]

    assert @agent.valid?
    assert_equal [ "openrouter:deepseek/deepseek-v4-pro-0813" ], @agent.subagent_models
  end

  test "invalid keys are rejected" do
    @agent.subagent_models = [ "openrouter:deepseek/deepseek-v4-pro-0813", "NotLowercase:model", "no-colon-here", "openrouter:" ]

    assert_not @agent.valid?
    assert @agent.errors[:subagent_models].any? { |message| message.include?("invalid entries") }
  end

  test "more than the maximum number of models is rejected" do
    @agent.subagent_models = (1..Agent::Subagents::MAX_SUBAGENT_MODELS + 1).map { |n| "openrouter:model-#{n}" }

    assert_not @agent.valid?
    assert_includes @agent.errors[:subagent_models], "can list at most #{Agent::Subagents::MAX_SUBAGENT_MODELS} models"
  end

  test "exactly the maximum number of well-formed models is allowed" do
    @agent.subagent_models = (1..Agent::Subagents::MAX_SUBAGENT_MODELS).map { |n| "openrouter:model-#{n}" }

    assert @agent.valid?
  end

  test "available_subagent_models is empty when disabled regardless of configured credentials" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.subagents_enabled = false
    @agent.subagent_models = [ "openrouter:deepseek/deepseek-v4-pro-0813" ]

    assert_empty @agent.available_subagent_models
  end

  test "available_subagent_models resolves catalogue entries and custom entries when enabled" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.update!(
      subagents_enabled: true,
      subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813", "openrouter:some-custom-model" ]
    )

    resolved = @agent.available_subagent_models
    assert_equal 2, resolved.size

    catalogue_entry = resolved.find { |entry| entry[:key] == "openrouter:deepseek/deepseek-v4-pro-0813" }
    assert catalogue_entry
    assert_equal "DeepSeek V4 Pro 0813", catalogue_entry[:label]
    assert_equal "deepseek/deepseek-v4-pro-0813", catalogue_entry[:model]
    assert_not catalogue_entry[:custom]

    custom_entry = resolved.find { |entry| entry[:key] == "openrouter:some-custom-model" }
    assert custom_entry
    assert custom_entry[:custom]
    assert_equal "some-custom-model", custom_entry[:model]
  end

  test "available_subagent_models drops keys whose provider has no credentials" do
    @agent.account.openrouter_api_key = "sk-or-test"
    @agent.update!(
      subagents_enabled: true,
      subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813", "anthropic:claude-opus-5" ]
    )

    assert_equal [ "openrouter:deepseek/deepseek-v4-pro-0813" ], @agent.available_subagent_models.map { |entry| entry[:key] }
  end

  test "sub-agents are available on the house, with no plan or a complimentary one" do
    assert @agent.subagents_available?

    entitlement = ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "complimentary",
      state: "complimentary", complimentary_granted_at: Time.current)
    assert @agent.subagents_available?

    # A complimentary resident that also bought a lower plan keeps them.
    entitlement.update!(source: "stripe", state: "active", tier: "life")
    assert @agent.subagents_available?
  end

  test "sub-agents come with the Work plan and not lower plans" do
    entitlement = ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe",
      state: "active", tier: "work")
    assert @agent.subagents_available?

    entitlement.update!(state: "grace")
    assert @agent.subagents_available?

    entitlement.update_columns(state: "held")
    assert_not @agent.subagents_available?

    %w[conversation life].each do |tier|
      entitlement.update_columns(state: "active", tier: tier)
      assert_not @agent.subagents_available?, tier
    end
  end

  test "a lower plan cannot switch sub-agents on, and a switch left on grants nothing" do
    @agent.account.update!(openrouter_api_key: "sk-or-test")
    @agent.update!(subagents_enabled: true, subagent_models: [ "openrouter:deepseek/deepseek-v4-pro-0813" ])
    assert_equal 1, @agent.available_subagent_models.size

    ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe", state: "active",
      tier: "life")
    assert_not @agent.subagents_permitted?
    assert_equal [], @agent.available_subagent_models
    assert @agent.update(name: "Renamed"), "an unrelated save still works with the switch left on"

    @agent.update!(subagents_enabled: false)
    @agent.subagents_enabled = true
    assert_not @agent.valid?
    assert_includes @agent.errors[:subagents_enabled], "Sub-agents come with the Work plan"
  end

  test "a paid birth waiting for its billing link is not taken for a resident on the house" do
    assert @agent.subagents_available?

    ResidentBirthOrder.create!(account: @agent.account, creator: users(:user_1), tier: "life", state: "born",
      agent: @agent)
    assert_not @agent.subagents_available?, "no entitlement yet, but this resident was paid for"

    ResidentEntitlement.create!(agent: @agent, account: @agent.account, source: "stripe", state: "active",
      tier: "work")
    assert @agent.subagents_available?, "once linked, the plan decides"
  end

end
