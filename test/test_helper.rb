ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  # 共通ログインヘルパー（判断メモ D-12）。当初 Devise::Test::IntegrationHelpers#sign_in
  # （Wardenのセッションを直接操作する高速な方式）を使っていたが、同じテスト内で
  # RecordNotFound由来の404レスポンスを2回続けて受けると、3回目以降のリクエストで
  # 認証が外れる不具合を確認した（実際に user_session_path へPOSTする方式では再現
  # しないため、Wardenのテストモード固有の問題で、実際のログインフローには影響しない）。
  # 再現条件を避けて回るより、確実に動く実ログインの方を選んだ。
  def sign_in(user, password: "password1234")
    post user_session_path, params: { user: { email: user.email, password: password } }
  end
end
