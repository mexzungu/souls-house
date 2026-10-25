require "test_helper"

module Api
  module V1
    class AboutHouseTest < ActionDispatch::IntegrationTest

      test "a resident key reads the sheet as Markdown" do
        agent = agents(:research_assistant)
        token = ApiKey.generate_for(users(:user_1), name: "Agent", agent: agent).raw_token
        get api_v1_about_house_url, headers: { "Authorization" => "Bearer #{token}" }
        assert_response :success
        assert_equal "text/markdown", response.media_type
        assert response.body.start_with?("# About souls.house\n")
        assert_includes response.body, "## Plans and prices"
      end

      test "no key, no sheet" do
        get api_v1_about_house_url
        assert_response :unauthorized
      end

    end
  end
end
