# Finds quiet rooms and judges each once per state with StalledThreadClassifier.
#
# Every verdict becomes a StalledThreadSweep row an admin can read. With
# Setting#stalled_sweep_wake off (shadow, the default) that is all; on, a
# verdict naming a resident goes to StalledThreadWake.
#
# Two switches: the site interval (Setting#stalled_sweep_minutes, 0 = off)
# and each account's own opt-in (Account#stalled_sweep_enabled). No room in an
# account that hasn't opted in is read or sent to Jev.
#
# A room is a candidate when it is active and respondable, has residents, its
# account has opted in and is enabled, its last message (StalledThreadSnapshot's
# definition) is older than the interval, and that state has no verdict yet.
# Candidates are ordered most recently quiet first, and each tick resumes the
# list where the previous one stopped (Setting#stalled_sweep_cursor), wrapping
# round. Rooms with a run going are skipped without a row and don't use the
# per-tick verdict budget; a room quiet for days is still judged, once, as the
# backlog drains.
class StalledThreadSweeper

  INTERVALS = [ 0, 10, 30, 60 ].freeze
  PER_TICK = 20
  # Bounds the cheap checks (busy rooms) a tick may make before giving up.
  MAX_CHECKS_PER_TICK = 200
  PROMPT_VERSION = "v3".freeze

  def self.interval
    minutes = Setting.instance.stalled_sweep_minutes.to_i
    minutes.positive? ? minutes.minutes : nil
  end

  def self.enabled?
    interval.present?
  end

  def initialize(now: Time.current, interval: self.class.interval, decide: UtilityInference.method(:decide),
    wake: StalledThreadWake.enabled?)
    @now = now
    @interval = interval
    @decide = decide
    @wake = wake
  end

  def call
    return [] unless @interval

    queue = candidates
    return [] if queue.empty?

    # Resume where the last tick stopped and wrap around, so rooms skipped as
    # busy can't hold the front of the queue every tick.
    setting = Setting.instance
    start = setting.stalled_sweep_cursor % queue.size
    verdicts = []
    checks = 0
    queue.rotate(start).each do |chat, message|
      break if verdicts.size >= PER_TICK || checks >= MAX_CHECKS_PER_TICK

      checks += 1
      sweep = judge(chat, message)
      verdicts << sweep if sweep
    end
    setting.update_column(:stalled_sweep_cursor, (start + checks) % queue.size)
    verdicts
  end

  # [chat, last message] pairs, most recently quiet first.
  def candidates
    chats = Chat.kept.active.joins(:account)
      .where(accounts: { stalled_sweep_enabled: true })
      .where(id: ChatAgent.select(:chat_id))
      .includes(:account, :agents).to_a
    lasts = StalledThreadSnapshot.last_messages(chats.map(&:id))
    quiet = lasts.values.select { |message| message.created_at <= @now - @interval }
    judged = StalledThreadSweep.where(message_id: quiet.map(&:id)).pluck(:message_id).to_set
    by_id = chats.index_by(&:id)
    quiet.reject { |message| judged.include?(message.id) }
      .sort_by { |message| [ -message.created_at.to_f, -message.id ] }
      .filter_map do |message|
        chat = by_id[message.chat_id]
        next unless chat.respondable? && !chat.account.disabled?

        [ chat, message ]
      end
  end

  def judge(chat, message)
    # A run going (or queued) in the room: it isn't stalled, it's working.
    # No row, so a later tick looks again once it has settled.
    return if chat.agents.any? { |agent| chat.agent_response_active?(agent) }

    snapshot = StalledThreadSnapshot.new(chat, at: @now, live: true)
    return if snapshot.last_message&.id != message.id

    state = snapshot.state
    return if state[:residents_in_room].any? { |r| r[:run_in_progress] == true }

    verdict = StalledThreadClassifier.call(state, decide: @decide)
    record(chat, message, state, verdict)
  rescue UtilityInference::InputTooLong, UtilityInference::InvalidResponse => error
    record_error(chat, message, error)
  end

  private

  def record(chat, message, state, verdict)
    residents = chat.agents.reorder("chat_agents.id").to_a
    scores = verdict.wake.each_with_index.map do |(resident, score), index|
      { agent_id: residents[index]&.to_param, name: resident[:name], score: score }
    end
    would_wake = verdict.wake_residents.map { |resident| resident[:name] }
    outcome = if would_wake.any? then "would_wake" elsif verdict.person_holds? then "person_holds" else "quiet" end
    sweep = StalledThreadSweep.create!(
      account: chat.account, chat: chat, message: message, outcome: outcome,
      scores: scores, person_holds: verdict.person_holds, would_wake: would_wake,
      quiet_minutes: state[:minutes_since_last_message], prompt_version: PROMPT_VERSION,
      human_message_id: last_human_message_id(chat)
    )
    StalledThreadWake.new(sweep).call if would_wake.any? && @wake
    sweep
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # The chain a wake belongs to (StalledThreadWake): the room's last message
  # from a person, the same boundary the handoff loop cap uses.
  def last_human_message_id(chat)
    chat.messages.where(role: "user").where.not(user_id: nil).maximum(:id)
  end

  def record_error(chat, message, error)
    StalledThreadSweep.create!(
      account: chat.account, chat: chat, message: message, outcome: "error",
      error_class: error.class.name, prompt_version: PROMPT_VERSION
    )
  rescue ActiveRecord::RecordNotUnique
    nil
  end

end
