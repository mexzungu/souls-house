require "test_helper"

class RegistrationsControllerTest < ActionDispatch::IntegrationTest

  test "should get signup page when not authenticated" do
    get signup_path
    assert_response :success
    assert_equal "registrations/new", inertia_component
  end

  test "should redirect to root when accessing signup while authenticated" do
    user = users(:user_1)
    post login_path, params: { email_address: user.email_address, password: "password123" }

    get signup_path
    assert_redirected_to root_path
    assert_equal "You are already signed in.", flash[:alert]
  end

  test "should create new user with valid email" do
    assert_difference("User.count", 1) do
      post signup_path, params: {
        email_address: "newuser@example.com"
      }
    end

    assert_redirected_to check_email_path
    assert_equal "Please check your email to confirm your account.", flash[:notice]

    # Verify the user was created without password
    user = User.last
    assert_equal "newuser@example.com", user.email_address
    assert_nil user.password_digest
    assert_not user.confirmed?
  end

  test "should not create user with invalid email" do
    assert_no_difference("User.count") do
      post signup_path, params: {
        email_address: "invalid-email"
      }
    end

    assert_redirected_to signup_path
    follow_redirect!
    errors = inertia_shared_props["errors"]
    assert errors.present?
    assert errors["email_address"].present?
    assert errors["email_address"].any? { |e| e.match?(/invalid/i) }
  end

  test "should not create user with blank email" do
    assert_no_difference("User.count") do
      post signup_path, params: {
        email_address: ""
      }
    end

    assert_redirected_to signup_path
    follow_redirect!
    errors = inertia_shared_props["errors"]
    assert errors.present?
    assert errors["email_address"].present?
  end

  test "should resend confirmation for existing unconfirmed user" do
    # Use unconfirmed user fixture
    user = users(:unconfirmed_user)

    assert_no_difference("User.count") do
      post signup_path, params: {
        email_address: user.email_address
      }
    end

    assert_redirected_to check_email_path
    assert_equal "Confirmation email resent. Please check your inbox.", flash[:notice]
  end

  test "should not allow signup with already confirmed email" do
    user = users(:user_1)

    assert_no_difference("User.count") do
      post signup_path, params: {
        email_address: user.email_address
      }
    end

    assert_redirected_to signup_path
    follow_redirect!
    errors = inertia_shared_props["errors"]
    assert errors.present?
    assert errors["email_address"].present?
    assert errors["email_address"].any? { |e| e.match?(/already registered/i) }
  end

  test "registration returns proper inertia errors structure" do
    post signup_path, params: {
      email_address: "invalid"
    }

    assert_redirected_to signup_path
    follow_redirect!
    errors = inertia_shared_props["errors"]
    assert_kind_of Hash, errors
    assert_kind_of Array, errors["email_address"]
  end

  test "should get check email page" do
    get check_email_path
    assert_response :success
    assert_equal "registrations/check_email", inertia_component
  end

  test "signup blocked when disabled" do
    Setting.instance.update!(allow_signups: false)

    get signup_path
    assert_redirected_to root_path
    assert_match(/disabled/, flash[:alert])
  end

  test "should confirm email with valid token" do
    user = User.create!(
      email_address: "toconfirm@example.com"
    )
    membership = user.personal_membership

    get email_confirmation_path(token: membership.confirmation_token_for_url)
    assert_redirected_to set_password_path
    assert_equal "Email confirmed! Please set your password.", flash[:notice]

    user.reload
    assert user.confirmed?
  end

  test "should handle invalid confirmation token" do
    get email_confirmation_path(token: "invalid_token")
    assert_redirected_to signup_path
    assert_equal "Invalid or expired confirmation link. Please sign up again.", flash[:alert]
  end

  test "should set password after confirmation" do
    # Create unconfirmed user
    user = User.create!(
      email_address: "newpass@example.com"
    )
    membership = user.personal_membership

    # Simulate email confirmation click
    get email_confirmation_path(token: membership.confirmation_token_for_url)
    assert_redirected_to set_password_path
    follow_redirect!

    assert_response :success
    assert_equal "registrations/set_password", inertia_component

    # Set the password
    patch set_password_path, params: {
      password: "newpassword123",
      password_confirmation: "newpassword123",
      first_name: "New",
      last_name: "User"
    }

    # Their only account is their own and it has no resident yet: the next
    # step is making one, not the marketing home page.
    assert_redirected_to new_account_agent_path(user.reload.personal_account)
    assert_equal "Account setup complete! Welcome!", flash[:notice]

    user.reload
    assert user.authenticate("newpassword123")
  end

  test "a rejected password keeps the names and states the same rule the form shows" do
    user = User.create!(email_address: "shortpass@example.com")
    get email_confirmation_path(token: user.personal_membership.confirmation_token_for_url)
    follow_redirect!
    assert_equal 8, inertia_props["props"]["password_min_length"]
    assert_equal 72, inertia_props["props"]["password_max_length"]
    @inertia_props = nil

    patch set_password_path, params: {
      password: "seven77",
      password_confirmation: "seven77",
      first_name: "Daniel",
      last_name: "Tenner"
    }

    assert_redirected_to set_password_path
    assert_includes flash[:errors], "Password is too short (minimum is 8 characters)"

    follow_redirect!
    page_user = inertia_props["props"]["user"]
    assert_equal "Daniel", page_user["first_name"]
    assert_equal "Tenner", page_user["last_name"]
    assert_nil user.reload.password_digest
  end

  test "an eight character password completes setup" do
    user = User.create!(email_address: "eightpass@example.com")
    get email_confirmation_path(token: user.personal_membership.confirmation_token_for_url)

    patch set_password_path, params: {
      password: "eight888",
      password_confirmation: "eight888",
      first_name: "Eight",
      last_name: "Chars"
    }

    assert_redirected_to new_account_agent_path(user.reload.personal_account)
    assert user.reload.authenticate("eight888")
  end

  test "a blank password does not complete setup" do
    user = User.create!(email_address: "blankpass@example.com")
    get email_confirmation_path(token: user.personal_membership.confirmation_token_for_url)

    patch set_password_path, params: { password: "", password_confirmation: "", first_name: "No", last_name: "Pass" }

    assert_redirected_to set_password_path
    assert_nil user.reload.password_digest
  end

end
