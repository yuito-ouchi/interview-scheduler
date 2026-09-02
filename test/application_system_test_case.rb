require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # 並列ワーカーごとに別コネクション/別DBになり、Capybara が起動する Puma
  # サーバースレッドと setup の書き込みが食い違って落ちることがあるため、
  # システムテストは直列で実行する。
  parallelize(workers: 1)

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ]
end
