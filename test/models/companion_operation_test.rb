require "test_helper"

class CompanionOperationTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    grant = CompanionEnrollmentGrant.create!(account: @agent.account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Fixture", device_request_id: "fixture",
      policy: { "residents" => [ { "id" => @agent.obfuscated_id,
        "volumes" => [ { "volume" => "fixture-volume", "access" => "read" } ], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "fixture")
    @device.update!(connection_epoch: "fixture-epoch")
  end

  def start_read
    CompanionOperation.start!(device: @device, agent: @agent, kind: "read",
      arguments: { "volume" => "fixture-volume", "path" => "fixture.txt", "limit" => 16 })
  end

  test "persists before dispatch then stores content separately and consumes once" do
    operation = start_read
    assert_equal "pending", operation.state
    assert operation.dispatch!
    assert_equal "dispatched", operation.reload.state
    assert operation.complete!(epoch: "fixture-epoch", revision: 1,
      data: "private fixture", content_type: "application/octet-stream")
    assert_equal "completed", operation.reload.state
    assert_not_includes operation.attributes.to_json, "private fixture"
    assert_equal [ "private fixture", "application/octet-stream" ], operation.take_body!
    assert_nil operation.take_body!
    assert_equal "completed", operation.reload.state
  end

  test "read grants do not grant writes exec other resident or other volume" do
    %w[write exec move].each do |kind|
      assert_raises(CompanionOperation::Refused) do
        CompanionOperation.start!(device: @device, agent: @agent, kind: kind, arguments: {})
      end
    end
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: agents(:code_reviewer), kind: "drives", arguments: {})
    end
    assert_raises(CompanionOperation::Refused) do
      CompanionOperation.start!(device: @device, agent: @agent, kind: "read", arguments: { "volume" => "other" })
    end
  end

  test "bounded concurrency and deadline free a slot without replay" do
    operations = 4.times.map { start_read }
    assert_raises(CompanionOperation::Refused) { start_read }
    operations.first.update!(deadline: 1.second.ago)
    assert start_read
    assert_equal "timed_out", operations.first.reload.state
    assert_not operations.first.dispatch!
  end

  test "late old epoch revoked paused and changed revision results are suppressed" do
    [ { connection_epoch: "new" }, { revoked_at: Time.current }, { paused: true }, { grant_revision: 2 } ].each do |change|
      @device.update!(connection_epoch: "fixture-epoch", revoked_at: nil, paused: false, grant_revision: 1)
      operation = start_read
      operation.dispatch!
      @device.update!(change)
      assert_not operation.complete!(epoch: "fixture-epoch", revision: 1, data: "not deliverable")
      assert_equal "cancelled", operation.reload.state
      assert_nil operation.body
    end
  end

  test "completed content is withheld on revocation or expiration" do
    operation = start_read
    operation.dispatch!
    operation.complete!(epoch: "fixture-epoch", revision: 1, data: "fixture")
    @device.update!(revoked_at: Time.current)
    assert_nil operation.take_body!
    assert_nil operation.reload.body
  end

  test "body expires independently from retained audit" do
    operation = start_read
    operation.dispatch!
    operation.complete!(epoch: "fixture-epoch", revision: 1, data: "fixture")
    id = operation.body.id
    travel 11.minutes
    CompanionBodyExpiryJob.perform_now(id)
    assert_nil operation.reload.body
    assert_equal "completed", operation.state
  end

end
