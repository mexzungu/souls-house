# A new resident speaks first (Daniel, ekMMZJ, 26 Oct: "there's already a
# conversation in the chat instead of being just an empty chat"). Once its
# first-wake orientation has finished, or failed with the runtime healthy, the
# house opens one conversation in Main with the resident seated, posts
# nothing itself, and wakes the resident there once with an initiation reason.
# The resident may say hello, or leave the first word to the person.
#
# Once only. The decision whether a conversation already exists and the
# creation are made under the agent's row lock, and the chat id and
# "greeting owed" are committed together; the wake is enqueued after commit
# and the sweep (FirstConversationSweepJob) re-offers anything left owed, so a
# process dying in between doesn't lose the greeting. A greeting that reached
# the runtime is final, even if the resident chose to stay quiet.
#
# Billing hold, pause and readiness are checked here and again at wake time;
# none is inferred from the orientation timestamps.
module Agents
  class FirstConversation

    # A greeting still owed after this long is dropped, not chased.
    GIVE_UP_AFTER = 1.day
    SYSTEM_TEST_TITLE_PREFIX = "system: agent test for".freeze

    def self.trigger?(agent)
      return false unless agent.born_hosted? && agent.created_by_user_id.present?
      return false if agent.first_conversation_chat_id.present?

      agent.orientation_completed_at.present? ||
        (agent.orientation_last_error_at.present? && agent.health_state == "healthy")
    end

    def self.offer_later(agent)
      FirstConversationJob.perform_later(agent.id) if trigger?(agent)
    end

    def self.open!(agent) = new(agent).open!
    def self.wake!(agent) = new(agent).wake!

    def initialize(agent)
      @agent = agent
    end

    # :opened, :existing, or a refusal symbol.
    def open!
      outcome = agent.with_lock do
        next :already_open if agent.first_conversation_chat_id.present?
        next :not_new_birth unless self.class.trigger?(agent)
        next refusal if refusal

        if (existing = person_started_chat)
          agent.update!(first_conversation_chat_id: existing.id, first_conversation_greeting: "skipped")
          next :existing
        end

        chat = agent.account.chats.create_with_message!(
          { title: "#{agent.name}'s first conversation", manual_responses: true, model_id: agent.model_id },
          agent_ids: [ agent.id ], automatic_response: false
        )
        agent.update!(first_conversation_chat_id: chat.id, first_conversation_greeting: "owed")
        :opened
      end
      FirstConversationWakeJob.perform_later(agent.id) if outcome == :opened
      outcome
    end

    # :sent, :skipped, :not_owed, or a refusal symbol (still owed).
    def wake!
      chat = nil
      outcome = agent.with_lock do
        next :not_owed unless agent.first_conversation_greeting == "owed"

        chat = agent.first_conversation_chat
        if chat.nil? || agent.birth_committed_at < GIVE_UP_AFTER.ago
          agent.update!(first_conversation_greeting: "skipped")
          next :skipped
        end
        # A person started their own conversation while this one was being
        # opened: theirs is the first conversation, and the empty one goes.
        if (existing = person_started_chat(excluding: chat))
          agent.update!(first_conversation_chat_id: existing.id, first_conversation_greeting: "skipped")
          chat.destroy! if chat.messages.empty?
          next :skipped
        end
        # A person has already written here: the ordinary reply answers them.
        if human_spoke?(chat)
          agent.update!(first_conversation_greeting: "skipped")
          next :skipped
        end
        next refusal if refusal

        agent.update!(first_conversation_greeting: "sent", first_conversation_woken_at: Time.current)
        :sent
      end
      return outcome unless outcome == :sent

      result = ExternalAgentResponseRequest.new(
        agent: agent, chat: chat, requested_by: "souls.house", initiation_reason: reason_text
      ).call
      # Status 0 means the request never reached the runtime; anything else
      # (a reply, a quiet completion, a run already going) settles it.
      return :sent unless result[:status].to_i.zero?

      reopen!
      :unreached
    rescue Agent::RuntimeAvailability::Unavailable
      reopen!
      :unavailable
    end

    def reason_text
      person = creator
      name = ResidentFacingName.for(person) || "the person who looks after this account"
      relation = if person && person.id == agent.created_by_user_id
        "who created this resident"
      else
        "who owns the account this resident lives in"
      end
      orientation = if agent.orientation_completed_at.present?
        "Your first-wake orientation completed."
      else
        "Your first-wake orientation did not complete; the runtime is healthy."
      end
      <<~TEXT.squish
        The house opened this conversation for you and #{name}, #{relation}.
        You can say hello in your own way: perhaps something that caught your attention in your seed,
        or a question you'd like to ask. There is no prescribed greeting, and you're welcome to leave
        the first word to them. If they've already written, respond to what they said instead.
        (#{orientation})
      TEXT
    end

    # For the onboarding page: where the first conversation is, and whether
    # the resident has written in it. A reply is a message the resident
    # posted during a run, not a house notice (those carry no run) or a
    # progress line.
    def self.presentation(agent)
      chat = agent.first_conversation_chat or return nil
      replied = chat.messages.kept.where(role: "assistant", agent_id: agent.id, progress_message: false)
        .where.not(runtime_interaction_id: nil).exists?
      { id: chat.to_param, has_reply: replied }
    end

    def creator
      agent.created_by_user || agent.account.owner
    end

    private

    attr_reader :agent

    # Never reached the runtime: still owed, for the sweep.
    def reopen!
      agent.with_lock do
        agent.update!(first_conversation_greeting: "owed", first_conversation_woken_at: nil) if agent.first_conversation_greeting == "sent"
      end
    end

    def refusal
      return :inactive unless agent.active?
      return :paused if agent.paused?
      return :billing_held if agent.billing_held?
      return :runtime_not_ready unless agent.external? && agent.health_state == "healthy"

      nil
    end

    def person_started_chat(excluding: nil)
      scope = agent.chats.where("chats.title IS NULL OR chats.title NOT LIKE ?", "#{SYSTEM_TEST_TITLE_PREFIX}%")
        .where(id: Message.kept.where(role: "user").where.not(user_id: nil).select(:chat_id))
      scope = scope.where.not(id: excluding.id) if excluding
      scope.order("chats.created_at ASC, chats.id ASC").first
    end

    def human_spoke?(chat)
      chat.messages.kept.where(role: "user").where.not(user_id: nil).exists?
    end

  end
end
