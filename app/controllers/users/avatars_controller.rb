class Users::AvatarsController < ApplicationController

  def destroy
    Current.user.profile&.retire_avatar!
    audit(:remove_avatar, Current.user)

    inertia_request? ?
      redirect_with_inertia_flash(:success, "Avatar removed successfully", edit_user_path) :
      render(json: { success: true }, status: :ok)
  end

  private

  def inertia_request?
    request.headers["X-Inertia"].present?
  end

end
