require "test_helper"

class StalledThreadWakeTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    [ @lume, @mira ].each do |agent|
      agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
        trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0)
    end
    @person = users(:user_1)
    @chat = @lume.account.chats.create!(title: "Quiet room", manual_responses: true, agents: [ @lume, @mira ])
    @chat.chat_agents.update_all(created_at: 1.day.ago)
    post(@person, "Please build it and get Mira to review.", at: 3.hours.ago)
    post(@mira, "Approved at abc123, merge once CI is green.", at: 2.hours.ago)
  end

  test "a resident judged to have a step is woken once, with a notice, carrying the sweep" do
    assert_enqueued_jobs(1, only: ManualAgentResponseJob) { sweep(lume: 0.9) }

    run = @chat.agent_runtime_interactions.sole
    assert_equal [ @lume, "queued" ], [ run.agent, run.execution_state ]
    sweep = run.stalled_thread_sweep
    assert_equal [ @lume.id ], sweep.woken_agent_ids
    assert_match "Stalled-thread check", @chat.messages.order(:id).last.content
    assert_match "STALLED-THREAD CHECK", sweep.nudge_text
    assert_match "grants no new permissions", sweep.nudge_text
  end

  test "shadow mode records the verdict and wakes nobody" do
    assert_no_difference(-> { AgentRuntimeInteraction.count }) do
      assert_no_difference(-> { Message.count }) { sweep(lume: 0.9, wake: false) }
    end
    assert_equal "would_wake", StalledThreadSweep.sole.outcome
  end

  test "the same chain is not woken twice; the room is told once that automation stopped" do
    sweep(lume: 0.9)
    finish_runs
    post(@lume, "Still waiting on CI.", at: 1.second.from_now)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweep(lume: 0.9) }
    assert_equal 1, stop_notices
    assert_equal({ @lume.name => "already_woken_in_chain" }, StalledThreadSweep.order(:id).last.held)

    post(@lume, "Hm.", at: 3.seconds.from_now)
    assert_no_difference(-> { Message.count }) { sweep(lume: 0.9) }
    assert_equal 1, stop_notices

    # A person's message starts a new chain.
    post(@person, "Any news?", at: 5.seconds.from_now)
    post(@lume, "Looking.", at: 7.seconds.from_now)
    assert_difference(-> { AgentRuntimeInteraction.count }, 1) { sweep(lume: 0.9) }
  end

  test "paused residents are never woken" do
    @lume.update!(paused: true)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweep(lume: 0.9) }
    assert_equal({ @lume.name => "paused" }, StalledThreadSweep.sole.held)
  end

  test "sweeper wakes count against the handoff loop cap" do
    @chat.account.update!(resident_handoff_cap: 1)
    sweep(lume: 0.9)
    finish_runs
    post(@lume, "Done, Mira over to you.", at: 1.second.from_now)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { sweep(lume: 0.1, mira: 0.9) }
    assert_equal({ @mira.name => "loop_cap" }, StalledThreadSweep.order(:id).last.held)
  end

  test "nothing happens if the room moved on before the wake" do
    sweeper = StalledThreadSweeper.new(now: 1.hour.from_now, interval: 10.minutes, wake: false, decide: answers(lume: 0.9))
    sweeper.call
    post(@person, "Never mind, I merged it.", at: 1.second.from_now)
    assert_no_difference(-> { AgentRuntimeInteraction.count }) { StalledThreadWake.new(StalledThreadSweep.sole).call }
  end

  test "a pause after the wake was reserved stops the run before it starts" do
    sweep(lume: 0.9)
    run = @chat.agent_runtime_interactions.sole
    @lume.update!(paused: true)
    ManualAgentResponseJob.perform_now(@chat, @lume, runtime_interaction_id: run.id)
    assert_equal "cancelled", run.reload.execution_state
  end

  private

  def sweep(lume: 0.1, mira: 0.1, wake: true)
    StalledThreadSweeper.new(now: 1.hour.from_now, interval: 10.minutes, wake: wake, decide: answers(lume: lume, mira: mira)).call
  end

  def answers(lume: 0.1, mira: 0.1)
    ->(**) { { "can_act:1" => lume, "can_act:2" => mira, "person_holds" => 0.1 } }
  end

  def stop_notices
    @chat.messages.where("content LIKE ?", "%Automation has stopped here%").count
  end

  def finish_runs
    @chat.agent_runtime_interactions.update_all(finished_at: Time.current, execution_state: "completed")
  end

  def post(author, content, at:)
    attributes = author.is_a?(Agent) ? { role: "assistant", agent: author } : { role: "user", user: author }
    message = @chat.messages.create!(content: content, **attributes)
    message.update_columns(created_at: at, updated_at: at)
    message
  end

end
