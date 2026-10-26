require "test_helper"

class Agents::FirstConversationTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @creator = @agent.account.owner
    @agent.update!(
      runtime: "external", health_state: "healthy", birth_committed_at: Time.current,
      uuid: SecureRandom.uuid_v7, created_by_user: @creator
    )
    clear_enqueued_jobs
  end

  def finish_orientation!
    @agent.update!(orientation_requested_at: Time.current, orientation_completed_at: Time.current)
  end

  def stub_runtime(status: 200, &block)
    calls = []
    request = Object.new
    request.define_singleton_method(:call) { calls << true; { status: status } }
    ExternalAgentResponseRequest.stub(:new, ->(**kwargs) { calls << kwargs; request }) { block.call }
    calls
  end

  def person_writes!(chat, text = "hello")
    chat.messages.create!(role: "user", user: @creator, content: text, suppress_automatic_dispatch: true)
  end

  def person_starts_chat!
    chat = @agent.account.chats.create!(title: "Hi", manual_responses: true, agent_ids: [ @agent.id ])
    person_writes!(chat)
    chat
  end

  test "a completed first wake opens the conversation, from any writer" do
    assert_enqueued_with(job: FirstConversationJob, args: [ @agent.id ]) { finish_orientation! }
  end

  test "orientation completing synchronously in OrientNewAgentJob opens the conversation" do
    request = Object.new
    def request.call = { status: 200 }
    ExternalAgentOrientationRequest.stub(:new, ->(**) { request }) do
      OrientNewAgentJob.perform_now(@agent.id)
    end
    assert_enqueued_jobs 1, only: FirstConversationJob
  end

  test "opens one conversation in Main with only the resident, and owes one greeting" do
    finish_orientation!
    assert_equal :opened, Agents::FirstConversation.open!(@agent)

    chat = @agent.reload.first_conversation_chat
    assert_equal "Research Assistant's first conversation", chat.title
    assert_nil chat.room
    assert chat.manual_responses?
    assert_equal [ @agent.id ], chat.agent_ids
    assert_empty chat.messages, "the house posts nothing"
    assert_equal "owed", @agent.first_conversation_greeting
    assert_enqueued_with(job: FirstConversationWakeJob, args: [ @agent.id ])
  end

  test "a failed orientation with a healthy runtime still opens it" do
    @agent.update!(orientation_last_error: "boom", orientation_last_error_at: Time.current)
    assert_enqueued_jobs 1, only: FirstConversationJob
    assert_equal :opened, Agents::FirstConversation.open!(@agent)
  end

  test "a failed orientation with an unhealthy runtime opens nothing" do
    @agent.update!(health_state: "unhealthy", orientation_last_error: "boom", orientation_last_error_at: Time.current)
    assert_enqueued_jobs 0, only: FirstConversationJob
    refute Agents::FirstConversation.trigger?(@agent)
  end

  test "residents born before the feature (no recorded creator) get nothing" do
    @agent.update!(created_by_user: nil)
    finish_orientation!
    assert_enqueued_jobs 0, only: FirstConversationJob
    assert_equal :not_new_birth, Agents::FirstConversation.open!(@agent)
  end

  test "a retry opens nothing new" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    assert_no_difference -> { Chat.count } do
      assert_equal :already_open, Agents::FirstConversation.open!(@agent)
      @agent.retry_orientation!
      @agent.update!(orientation_completed_at: Time.current)
      perform_enqueued_jobs(only: FirstConversationJob)
    end
  end

  test "a conversation a person already started is linked instead, and no greeting is owed" do
    existing = person_starts_chat!
    finish_orientation!
    assert_no_difference -> { Chat.count } do
      assert_equal :existing, Agents::FirstConversation.open!(@agent)
    end
    assert_equal existing, @agent.reload.first_conversation_chat
    assert_equal "skipped", @agent.first_conversation_greeting
    assert_enqueued_jobs 0, only: FirstConversationWakeJob
  end

  test "the owner's runtime test conversation is not a person-started conversation" do
    test_chat = @agent.account.chats.create!(title: "system: agent test for #{@agent.name}", manual_responses: true, agent_ids: [ @agent.id ])
    person_writes!(test_chat)
    finish_orientation!
    assert_equal :opened, Agents::FirstConversation.open!(@agent)
  end

  test "a person starting a conversation while it was being opened wins, and the empty one goes" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    opened = @agent.reload.first_conversation_chat
    theirs = person_starts_chat!

    calls = stub_runtime { assert_equal :skipped, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    assert_equal theirs, @agent.reload.first_conversation_chat
    refute Chat.exists?(opened.id)
  end

  test "once a person has written in it, the ordinary reply answers them instead" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    person_writes!(@agent.reload.first_conversation_chat)

    calls = stub_runtime { assert_equal :skipped, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    assert_equal "skipped", @agent.reload.first_conversation_greeting
  end

  test "the wake carries the reason, names the creator and states orientation" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    calls = stub_runtime { assert_equal :sent, Agents::FirstConversation.wake!(@agent) }

    kwargs = calls.first
    assert_equal @agent.first_conversation_chat, kwargs[:chat]
    assert_includes kwargs[:initiation_reason], "#{ResidentFacingName.for(@creator)}, who created this resident"
    assert_includes kwargs[:initiation_reason], "no prescribed greeting"
    assert_includes kwargs[:initiation_reason], "orientation completed"
    assert_equal "sent", @agent.reload.first_conversation_greeting
    assert_predicate @agent.first_conversation_woken_at, :present?
  end

  test "after a failed orientation the reason says so, and an owner standing in is named as owner" do
    @agent.update!(orientation_last_error: "boom", orientation_last_error_at: Time.current)
    first = Agents::FirstConversation.new(@agent)
    assert_includes first.reason_text, "did not complete"

    @agent.update_column(:created_by_user_id, User.where.not(id: @creator.id).first.id)
    @agent.reload.created_by_user.destroy!
    text = Agents::FirstConversation.new(@agent.reload).reason_text
    assert_includes text, "who owns the account"
    refute_includes text, "created this resident"
  end

  test "a quiet completion is final: no second wake, nothing for the sweep" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    stub_runtime { Agents::FirstConversation.wake!(@agent) }
    clear_enqueued_jobs

    calls = stub_runtime { assert_equal :not_owed, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    FirstConversationSweepJob.perform_now
    assert_enqueued_jobs 0, only: [ FirstConversationJob, FirstConversationWakeJob ]
  end

  test "a wake that never reached the runtime stays owed" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    stub_runtime(status: 0) { assert_equal :unreached, Agents::FirstConversation.wake!(@agent) }
    assert_equal "owed", @agent.reload.first_conversation_greeting
  end

  test "a process dying after the chat is saved but before the wake is enqueued is recovered by the sweep" do
    finish_orientation!
    FirstConversationWakeJob.stub(:perform_later, ->(*) { raise "process died" }) do
      assert_raises(RuntimeError) { Agents::FirstConversation.open!(@agent) }
    end
    assert_equal "owed", @agent.reload.first_conversation_greeting
    clear_enqueued_jobs

    FirstConversationSweepJob.perform_now
    assert_enqueued_with(job: FirstConversationWakeJob, args: [ @agent.id ])
  end

  test "the sweep opens a conversation whose job was lost, and drops greetings owed past a day" do
    finish_orientation!
    clear_enqueued_jobs
    FirstConversationSweepJob.perform_now
    assert_enqueued_with(job: FirstConversationJob, args: [ @agent.id ])

    Agents::FirstConversation.open!(@agent)
    @agent.update_column(:birth_committed_at, 2.days.ago)
    FirstConversationSweepJob.perform_now
    assert_equal "skipped", @agent.reload.first_conversation_greeting
  end

  test "billing hold, pause and an unready runtime open nothing" do
    finish_orientation!
    @agent.stub(:billing_held?, true) do
      assert_equal :billing_held, Agents::FirstConversation.open!(@agent)
    end
    @agent.update!(paused: true)
    assert_equal :paused, Agents::FirstConversation.open!(@agent)
    @agent.update!(paused: false, health_state: "unhealthy")
    assert_equal :runtime_not_ready, Agents::FirstConversation.open!(@agent)
    assert_nil @agent.reload.first_conversation_chat_id
  end

  test "a pause after opening holds the greeting rather than sending it" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    @agent.update!(paused: true)
    calls = stub_runtime { assert_equal :paused, Agents::FirstConversation.wake!(@agent) }
    assert_empty calls
    assert_equal "owed", @agent.reload.first_conversation_greeting
  end

  test "the page sees the conversation, and a reply only once the resident posts during a run" do
    finish_orientation!
    Agents::FirstConversation.open!(@agent)
    chat = @agent.reload.first_conversation_chat
    assert_equal({ id: chat.to_param, has_reply: false }, Agents::FirstConversation.presentation(@agent))

    chat.messages.create!(role: "assistant", agent: @agent, content: "_Research Assistant is currently unreachable._")
    refute Agents::FirstConversation.presentation(@agent)[:has_reply]

    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: chat, trigger_kind: "conversation",
      conversation_obfuscated_id: chat.to_param, requested_by: "souls.house", session_id: "s", started_at: Time.current)
    chat.messages.create!(role: "assistant", agent: @agent, content: "Hello.", runtime_interaction_id: interaction.id)
    assert Agents::FirstConversation.presentation(@agent)[:has_reply]
  end

end
