# Acts on a sweep that judged a resident has a step to take (slice 3 of
# BjZQAe). Runs only when Setting#stalled_sweep_wake is on.
#
# Brakes:
# - One wake per resident per chain. A chain is the stretch since the room's
#   last message from a person; a notice, a resident's reply or a reworded
#   promise does not start a new one. A resident judged stuck again in the
#   same chain is not woken again: the room is told once that automation has
#   stopped, without saying who owes what.
# - Sweeper wakes count against the account's resident handoff cap
#   (MessageHandoff) together with handoffs since the last person's message.
# - Paused or unavailable residents are never woken; pause is read under a
#   row lock, as FollowThroughCheckJob does.
# - Evidence boundary: under the room lock, the room's last message must
#   still be the one judged.
class StalledThreadWake

  def self.enabled?
    Setting.instance.stalled_sweep_wake?
  end

  def initialize(sweep)
    @sweep = sweep
    @chat = sweep.chat
  end

  def call
    return if @sweep.would_wake.empty?

    @chat.transaction do
      @chat.lock!
      @sweep.lock!
      next unless current_last_message_id == @sweep.message_id

      residents_to_consider.each { |agent| consider(agent) }
      @sweep.save!
    end
  end

  def nudge_notice(agent)
    "[System Notice] Stalled-thread check: this room has been quiet for #{@sweep.quiet_minutes} minutes, and it looks " \
      "like #{agent.name} has a step to take. Waking #{agent.name} once to pick it up or say what's blocking."
  end

  def stopped_notice(agent)
    "[System Notice] Stalled-thread check: #{agent.name} was already woken once here since the last message from a " \
      "person, and the room still looks stuck. Automation has stopped here; no further automatic wakes until someone posts."
  end

  private

  def residents_to_consider
    names = @sweep.would_wake
    @chat.agents.reorder("chat_agents.id").select { |agent| names.include?(agent.name) }
  end

  def consider(agent)
    if woken_in_chain?(agent)
      hold(agent, "already_woken_in_chain")
      stop!(agent) unless stopped_in_chain?
      return
    end
    return hold(agent, "loop_cap") if loop_cap_reached?

    agent.lock!
    return hold(agent, "paused") if agent.paused?
    return hold(agent, "unavailable") unless agent.eligible_for_conversation?

    # Reserve first: if the resident can't be woken, no notice claims it was.
    AgentRuntimeInteraction.reserve!(agent: agent, chat: @chat, enqueue: true, stalled_thread_sweep: @sweep)
    @chat.messages.create!(role: "user", content: nudge_notice(agent))
    @sweep.woken_agent_ids = (@sweep.woken_agent_ids + [ agent.id ]).uniq
  rescue Agent::RuntimeAvailability::Unavailable, Chat::AlreadyResponding, ArgumentError => error
    hold(agent, error.class.name.demodulize.underscore)
  end

  def hold(agent, reason)
    @sweep.held = @sweep.held.merge(agent.name => reason)
  end

  def stop!(agent)
    @chat.messages.create!(role: "user", content: stopped_notice(agent))
    @sweep.stopped = true
  end

  def chain_sweeps
    StalledThreadSweep.where(chat: @chat, human_message_id: @sweep.human_message_id).where.not(id: @sweep.id)
  end

  def woken_in_chain?(agent)
    chain_sweeps.where("woken_agent_ids @> ?", [ agent.id ].to_json).exists?
  end

  def stopped_in_chain?
    chain_sweeps.where(stopped: true).exists?
  end

  def loop_cap_reached?
    cap = @chat.account.resident_handoff_cap
    return true if cap.zero?

    handoffs = MessageHandoff.since_last_human_message(@chat)
      .where("reason IS NULL OR reason NOT IN (?)", [ MessageHandoff::LOOP_CAP_REASON, MessageHandoff::HANDOFFS_OFF_REASON ]).count
    wakes = chain_sweeps.sum { |sweep| sweep.woken_agent_ids.size }
    handoffs + wakes >= cap
  end

  def current_last_message_id
    @chat.messages.kept.where(role: %w[user assistant], progress_message: false).reorder(created_at: :desc, id: :desc).pick(:id)
  end

end
