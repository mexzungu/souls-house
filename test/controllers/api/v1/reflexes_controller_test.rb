require "test_helper"

module Api
  module V1
    class ReflexesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @peer = agents(:code_reviewer)
        @headers = auth(ApiKey.generate_for(@user, name: "Reflexes", agent: @agent))
        @peer_headers = auth(ApiKey.generate_for(@user, name: "Peer reflexes", agent: @peer))
      end

      test "a resident writes, lists and discards its own reflex" do
        post api_v1_reflexes_url, params: attrs, headers: @headers, as: :json
        assert_response :created
        assert_equal "no-store", response.headers["Cache-Control"]
        body = response.parsed_body["reflex"]
        assert_equal "Follow-up", body["name"]
        assert_not body.key?("live")
        reflex = Reflex.find(body["id"])
        assert_equal @agent, reflex.agent

        get api_v1_reflexes_url, headers: @headers
        assert_response :ok
        assert_equal [ body["id"] ], response.parsed_body["reflexes"].pluck("id")
        assert_equal false, response.parsed_body["enabled"]

        delete api_v1_reflex_url(reflex), headers: @headers
        assert_response :ok
        assert reflex.reload.discarded?
        assert response.parsed_body.dig("reflex", "discarded_at").present?

        get api_v1_reflexes_url, headers: @headers
        assert_empty response.parsed_body["reflexes"]
        get api_v1_reflexes_url, params: { include_discarded: "true" }, headers: @headers
        assert_equal [ reflex.to_param ], response.parsed_body["reflexes"].pluck("id")

        # A discarded reflex is gone.
        delete api_v1_reflex_url(reflex), headers: @headers
        assert_response :not_found
      end

      test "index reports whether the check is switched on" do
        Setting.instance.update!(reflexes_scope: "account_choice")
        @agent.account.update!(reflexes_enabled: true)
        get api_v1_reflexes_url, headers: @headers
        assert_equal true, response.parsed_body["enabled"]

        # The site overrides the account either way.
        Setting.instance.update!(reflexes_scope: "disabled")
        get api_v1_reflexes_url, headers: @headers
        assert_equal false, response.parsed_body["enabled"]

        @agent.account.update!(reflexes_enabled: false)
        Setting.instance.update!(reflexes_scope: "enabled")
        get api_v1_reflexes_url, headers: @headers
        assert_equal true, response.parsed_body["enabled"]
      end

      test "create cannot set agent or another resident" do
        post api_v1_reflexes_url, params: attrs.merge(agent_id: @peer.id), headers: @headers, as: :json
        assert_response :created
        reflex = Reflex.find(response.parsed_body.dig("reflex", "id"))
        assert_equal @agent, reflex.agent
      end

      test "validation errors are unprocessable" do
        post api_v1_reflexes_url, params: attrs.merge(name: ""), headers: @headers, as: :json
        assert_response :unprocessable_entity
        assert_match "Name", response.parsed_body["errors"].join

        post api_v1_reflexes_url, params: attrs.merge(reminder: "r" * (Reflex::REMINDER_LENGTH + 1)), headers: @headers, as: :json
        assert_response :unprocessable_entity

        Reflex::MAX_KEPT.times { |i| @agent.reflexes.create!(name: "R#{i}", shape: "Q?", reminder: "R") }
        assert_no_difference "Reflex.count" do
          post api_v1_reflexes_url, params: attrs, headers: @headers, as: :json
        end
        assert_response :unprocessable_entity
        assert_match "at most", response.parsed_body["errors"].join
      end

      test "a reflex cannot be edited: there is no update" do
        reflex = @agent.reflexes.create!(attrs)
        patch "/api/v1/reflexes/#{reflex.to_param}", params: { live: false, shape: "A new question?" }, headers: @headers, as: :json
        assert_response :not_found
        reflex.reload
        assert_equal attrs[:shape], reflex.shape
        assert_not reflex.discarded?
      end

      test "a resident reaches only its own reflexes" do
        theirs = @peer.reflexes.create!(attrs)
        delete api_v1_reflex_url(theirs), headers: @headers
        assert_response :not_found
        get api_v1_reflexes_url, headers: @headers
        assert_empty response.parsed_body["reflexes"]
        assert_not theirs.reload.discarded?

        get api_v1_reflexes_url, headers: @peer_headers
        assert_equal [ theirs.to_param ], response.parsed_body["reflexes"].pluck("id")
      end

      test "human keys, including site admins, are forbidden" do
        reflex = @agent.reflexes.create!(attrs)
        [ @user, users(:site_admin_user) ].each do |user|
          headers = auth(ApiKey.generate_for(user, name: "Human reflex attempt"))
          get api_v1_reflexes_url, headers: headers
          assert_response :forbidden
          assert_equal "no-store", response.headers["Cache-Control"]
          post api_v1_reflexes_url, params: attrs, headers: headers, as: :json
          assert_response :forbidden
          delete api_v1_reflex_url(reflex), headers: headers
          assert_response :forbidden
        end
        assert_not reflex.reload.discarded?
      end

      test "missing key is rejected" do
        get api_v1_reflexes_url
        assert_response :unauthorized
      end

      private

      def attrs
        { name: "Follow-up", shape: "Does the post promise a follow-up?", reminder: "Write the follow-up down." }
      end

      def auth(key)
        { "Authorization" => "Bearer #{key.raw_token}" }
      end

    end
  end
end
