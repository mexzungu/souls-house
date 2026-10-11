require "test_helper"
require "webmock/minitest"

# Real simultaneous posts on separate connections. Non-transactional so the
# row lock on the integration is actually contended.
class XPosterConcurrencyTest < ActiveSupport::TestCase

  self.use_transactional_tests = false

  setup do
    @agent = agents(:research_assistant)
    XIntegration.where(account_id: @agent.account_id).destroy_all
    @integration = XIntegration.create!(
      account: @agent.account, enabled: true, daily_post_limit: 2, x_username: "househandle",
      access_token: "live-token", refresh_token: "refresh-1", token_expires_at: 2.hours.from_now
    )
    @ids = (1..100).to_a
    @id_lock = Mutex.new
    @stub = stub_request(:post, "https://api.x.com/2/tweets").to_return do
      sleep 0.05
      id = @id_lock.synchronize { @ids.shift }
      { status: 201, body: { data: { id: id.to_s } }.to_json, headers: { "Content-Type" => "application/json" } }
    end
  end

  teardown do
    @integration&.tweet_logs&.delete_all
    @integration&.destroy
  end

  test "simultaneous posts cannot overshoot the daily ceiling" do
    outcomes = race(6) { |i| post!("Post #{i}", key: "key-#{i}") }

    assert_equal 2, outcomes.count { |outcome| outcome == "posted" }
    assert_equal 4, outcomes.count { |outcome| outcome == "daily_limit_reached" }
    assert_requested @stub, times: 2
    assert_equal 2, @integration.tweet_logs.count
  end

  test "simultaneous posts with one key send exactly once" do
    @integration.update!(daily_post_limit: 20)

    outcomes = race(5) { post!("Same post", key: "one-key") }

    assert_equal [ "posted" ], outcomes.uniq.compact - [ "pending" ]
    assert_requested @stub, times: 1
    assert_equal 1, @integration.tweet_logs.count
  end

  test "switching posting off stops posts that have not reserved yet" do
    @integration.update!(enabled: false)

    outcomes = race(3) { |i| post!("Post #{i}", key: "off-#{i}") }

    assert_equal [ "posting_disabled" ], outcomes.uniq
    assert_not_requested @stub
  end

  private

  def post!(text, key:)
    XPoster.new(agent: Agent.find(@agent.id)).post!(text:, idempotency_key: key).log.status
  rescue XPoster::Refused => e
    e.code
  end

  def race(count)
    gate = Queue.new
    results = Queue.new
    threads = count.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          results << yield(i)
        end
      end
    end
    count.times { gate << true }
    threads.each { |thread| thread.join(20) }
    Array.new(results.size) { results.pop }
  end

end
