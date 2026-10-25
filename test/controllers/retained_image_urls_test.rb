require "test_helper"

# Old signed URLs of a removed or replaced avatar or logo stop serving, while
# the bytes stay retained (#93).
class RetainedImageUrlsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @profile = @user.profile
  end

  test "removing an avatar through the web keeps its bytes and hides its old URLs" do
    sign_in @user
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob
    urls = [ blob_url(blob), representation_url(blob) ]
    urls.each { |url| assert_served url }

    delete user_avatar_path, headers: { "X-Inertia" => true }

    assert_equal [ blob.id ], @profile.reload.retired_avatars.blobs.pluck(:id)
    assert blob.service.exist?(blob.key)
    urls.each { |url| assert_hidden url }
  end

  test "a replaced avatar's old URL is hidden and the new one served" do
    @profile.avatar.attach(png("first.png"))
    old_url = blob_url(@profile.avatar.blob)
    @profile.update!(avatar: png("second.png"))

    assert_hidden old_url
    assert_served blob_url(@profile.reload.avatar.blob)
  end

  test "a retired blob still attached to a live owner stays served" do
    @profile.avatar.attach(png("first.png"))
    blob = @profile.avatar.blob
    chat = accounts(:personal_account).chats.create!(model_id: "openrouter/auto", title: "Shared")
    chat.messages.create!(content: "Same bytes", role: "user", user: @user).attachments.attach(blob)

    @profile.retire_avatar!

    assert_served blob_url(blob)
  end

  test "removing the site logo keeps its bytes and hides its URL" do
    sign_in users(:site_admin_user)
    Setting.instance.logo.attach(png("logo.png"))
    blob = Setting.instance.logo.blob
    url = blob_url(blob)

    patch admin_settings_path, params: { setting: { remove_logo: true } }

    assert_redirected_to admin_settings_path
    setting = Setting.instance.reload
    assert_not setting.logo.attached?
    assert_equal [ blob.id ], setting.retired_logos.blobs.pluck(:id)
    assert blob.service.exist?(blob.key)
    assert_hidden url
  end

  private

  def png(name)
    { io: file_fixture("test_avatar.png").open, filename: name, content_type: "image/png" }
  end

  def blob_url(blob)
    Rails.application.routes.url_helpers.rails_blob_path(blob, only_path: true)
  end

  def representation_url(blob)
    Rails.application.routes.url_helpers.rails_representation_path(blob.variant(resize_to_fill: [ 200, 200 ]), only_path: true)
  end

  def assert_served(url)
    get url
    assert_response :redirect, url
  end

  def assert_hidden(url)
    get url
    follow_redirect! if response.redirect?
    assert_response :not_found, url
  end

end
