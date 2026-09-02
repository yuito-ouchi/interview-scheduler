require "application_system_test_case"

# 主動線（画面①・①b）をブラウザ経由で通す。§6.6の操作フローそのもの。
# CSSレイアウト崩れ（overflow/flexの高さ潰れ、予定ブロックの重なり等）は
# Minitestの単体テストでは検出できず、この種のテストで初めて拾える。
class MeetingsTest < ApplicationSystemTestCase
  setup do
    @operator = User.create!(name: "採用 花子", email: "op@example.com", operator: true)
    @iv1 = User.create!(name: "伊藤 一郎", email: "ito@example.com", participant: true)
    @iv2 = User.create!(name: "佐藤 次郎", email: "sato@example.com", participant: true)

    (1..5).each do |wday|
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
        start_time: "10:00", end_time: "18:00", rule_type: "allow")
    end

    visit login_path
    select @operator.name, from: "user_id"
    click_on "この操作者で開始"
    # ログイン直後にページ遷移を待たず次の visit を呼ぶと、Set-Cookie が
    # ブラウザに反映しきる前にナビゲーションを打ち切ってしまい、次のリクエ
    # ストが未ログイン扱いで /login に戻される（実際に発生したflaky症状）。
    # root_path が meetings#new そのものなので、ここで読み込み完了を待てば
    # 改めて visit new_meeting_path し直す必要もない。
    assert_text "ミーティングを組む"
  end

  test "参加者を選び、空き枠から予約を確定できる" do
    check @iv1.name
    check @iv2.name
    # チェックのたびに個別に自動送信されるため（本文§6.4）、両方が反映された
    # 週ラベルが出るまで待ってから次に進む。片方だけ反映された時点で先に進む
    # と、翌週リンクが古い user_ids のまま生成されて選択が欠ける。
    assert_text "伊藤 一郎・佐藤 次郎"

    # 実行日によっては今週の枠が既に過去（BR-08/§9.3-1）のため、
    # 確実に未来である翌週で確認する。
    click_on "翌週 →"
    assert_selector ".seg__pick", minimum: 1
    first(".seg__pick").click

    within "#booking_form" do
      fill_in "ゲスト名", with: "山田太郎"
      click_on "予約する"
    end

    assert_text "予約を確定しました"
    assert_text "山田太郎 様"
    assert_text "伊藤 一郎"
    assert_text "佐藤 次郎"
  end
end
