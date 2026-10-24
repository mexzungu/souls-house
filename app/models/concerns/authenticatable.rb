# app/models/concerns/authenticatable.rb
module Authenticatable

  extend ActiveSupport::Concern

  # The one password length rule. Forms read it from here so the hint the
  # user sees and the validation that runs cannot drift apart again.
  PASSWORD_LENGTH = 8..72

  included do
    has_secure_password validations: false
    has_many :sessions, dependent: :destroy

    generates_token_for :password_reset, expires_in: 2.hours do
      password_salt&.last(10)
    end

    # Password validations: whenever a password is being set. Invited users
    # with no password yet set nothing, so they pass until they choose one.
    validates :password, confirmation: true, length: { in: PASSWORD_LENGTH },
                        if: :password_digest_changed?
  end

  def send_password_reset
    update_columns(password_reset_token: nil, password_reset_sent_at: Time.current)
    PasswordsMailer.reset(self).deliver_later
  end

  def password_reset_token_for_url
    return unless password_reset_sent_at.present?

    generate_token_for(:password_reset)
  end

  def password_reset_expired?
    return true unless password_reset_sent_at
    password_reset_sent_at < 2.hours.ago
  end

  def clear_password_reset_token!
    update_columns(password_reset_token: nil, password_reset_sent_at: nil)
  end

  def can_login?
    confirmed? && password_digest?
  end

  # Check if user was created via invitation and hasn't set up their account yet
  # These users don't require a password until they confirm their account
  def created_via_invitation?
    memberships.any?(&:invitation?) && !confirmed?
  end

end
