require "test_helper"

# 別紙A A-2-5 の境界条件（16 ケース）。
# 仕様書 §4.4 は 11 ケースだが、主動線の入れ替え（H2-01〜H2-05）で
# allow/block の合成（12〜14）と週走査（15〜16）が追加された別紙A が最新。
#
# 基準の要求区間：2026-09-02（水・wday 3）14:00-15:00。
# テナントルール：平日 10:00-18:00 allow ／ 12:00-13:00 block（昼休み）。
class AvailabilityCheckerTest < ActiveSupport::TestCase
  BASE_DAY = "2026-09-02".freeze # 水曜
  SATURDAY = "2026-09-05".freeze
  SUNDAY   = "2026-09-06".freeze

  setup do
    (1..5).each do |wday|
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
                               start_time: "10:00", end_time: "18:00", rule_type: "allow")
      AvailabilityRule.create!(user_id: nil, day_of_week: wday,
                               start_time: "12:00", end_time: "13:00", rule_type: "block", label: "昼休み")
    end
    @user = User.create!(name: "面接 太郎", email: "ivr@example.com", interviewer: true)
  end

  # --- ヘルパ ---------------------------------------------------------------
  # 実運用と同じく includes/preload 済みのレコードを渡す（A-2-4）。
  def result_for(from, to, user: @user)
    loaded = User.includes(:availability_rules, :calendar_events).find(user.id)
    checker(from, to).call([ loaded ]).first
  end

  def checker(from, to)
    AvailabilityChecker.new(start_at: Time.zone.parse(from), end_at: Time.zone.parse(to))
  end

  def event!(from, to, title:, all_day: false, user: @user)
    user.calendar_events.create!(source: "external", title: title, all_day: all_day,
                                 start_at: Time.zone.parse(from), end_at: Time.zone.parse(to))
  end

  def rule!(wday, from, to, type, label: nil, user: @user)
    user.availability_rules.create!(day_of_week: wday, start_time: from, end_time: to,
                                    rule_type: type, label: label)
  end

  # --- 前提の確認 --------------------------------------------------------------
  test "予定もルール違反もなければ空き" do
    assert result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00").available
  end

  # --- 区間の重なり（3〜6 は同じ式だが符号ミスが出やすいので個別に）-------------
  test "1. 既存の終了＝要求の開始（隣接）は空き" do
    event!("#{BASE_DAY} 13:00", "#{BASE_DAY} 14:00", title: "部門定例")
    assert result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00").available
  end

  test "2. 既存の開始＝要求の終了（隣接）は空き" do
    event!("#{BASE_DAY} 15:00", "#{BASE_DAY} 16:00", title: "1on1")
    assert result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00").available
  end

  test "3. 既存が要求を完全に含むは不可" do
    event!("#{BASE_DAY} 13:00", "#{BASE_DAY} 16:00", title: "社外研修")
    res = result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00")
    assert_not res.available
    assert_equal "予定あり（社外研修）", res.reason
  end

  test "4. 要求が既存を完全に含むは不可" do
    event!("#{BASE_DAY} 14:15", "#{BASE_DAY} 14:45", title: "電話")
    res = result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00")
    assert_not res.available
    assert_equal "予定あり（電話）", res.reason
  end

  test "5. 前方で部分的に重なるは不可" do
    event!("#{BASE_DAY} 13:30", "#{BASE_DAY} 14:30", title: "採用会議")
    assert_not result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00").available
  end

  test "6. 後方で部分的に重なるは不可" do
    event!("#{BASE_DAY} 14:30", "#{BASE_DAY} 15:30", title: "面談")
    assert_not result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00").available
  end

  test "7. 終日予定がある日は不可" do
    event!("#{BASE_DAY} 00:00", "#{BASE_DAY} 23:59", title: "有給", all_day: true)
    res = result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00")
    assert_not res.available
    assert_equal "終日予定（有給）", res.reason
  end

  test "8. 要求終了が営業時間を超えるは不可（17:30開始60分／営業18:00まで）" do
    res = result_for("#{BASE_DAY} 17:30", "#{BASE_DAY} 18:30")
    assert_not res.available
    assert_equal "営業時間外", res.reason
  end

  test "9. 土曜・日曜は不可（テナント allow が存在しない）" do
    sat = result_for("#{SATURDAY} 14:00", "#{SATURDAY} 15:00")
    sun = result_for("#{SUNDAY} 14:00", "#{SUNDAY} 15:00")
    assert_not sat.available
    assert_equal "営業日外", sat.reason
    assert_not sun.available
    assert_equal "営業日外", sun.reason
  end

  test "10. 個人 block ルールと重なるは不可（ラベル表示）" do
    rule!(3, "14:00", "14:30", "block", label: "通院")
    res = result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00")
    assert_not res.available
    assert_equal "予約不可時間（通院）", res.reason
  end

  test "11. JSTで入力しUTCで保存した予定を、JSTで再判定して重なりを検出する" do
    e = event!("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00", title: "面談")
    assert_equal 5, e.reload.start_at.utc.hour, "14:00 JST は 05:00 UTC で保存される"

    res = result_for("#{BASE_DAY} 14:30", "#{BASE_DAY} 15:30")
    assert_not res.available
    assert_equal "予定あり（面談）", res.reason
  end

  # --- allow/block の合成（BR-12：allow と block で向きが逆）-------------------
  test "12. テナント10-18 allow・個人13-17 allow で 11:00 を要求すると不可（積集合）" do
    rule!(3, "13:00", "17:00", "allow")
    res = result_for("#{BASE_DAY} 11:00", "#{BASE_DAY} 11:30")
    assert_not res.available
    assert_equal "営業時間外", res.reason
  end

  test "12b. 同条件で積集合の内側（14:00）なら空き" do
    rule!(3, "13:00", "17:00", "allow")
    assert result_for("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00").available
  end

  test "13. テナント allow がない曜日は、個人 allow があっても不可" do
    rule!(0, "10:00", "18:00", "allow") # 日曜に個人 allow
    res = result_for("#{SUNDAY} 14:00", "#{SUNDAY} 15:00")
    assert_not res.available
    assert_equal "営業日外", res.reason
  end

  test "14. テナント block と個人 block の和集合。いずれに重なっても不可" do
    rule!(3, "15:00", "16:00", "block", label: "研修")

    hit_tenant = result_for("#{BASE_DAY} 12:30", "#{BASE_DAY} 12:45")
    assert_not hit_tenant.available
    assert_equal "予約不可時間（昼休み）", hit_tenant.reason

    hit_personal = result_for("#{BASE_DAY} 15:00", "#{BASE_DAY} 15:30")
    assert_not hit_personal.available
    assert_equal "予約不可時間（研修）", hit_personal.reason
  end

  # --- 週走査（WeeklySlotFinder）------------------------------------------------
  test "15. WeeklySlotFinder が営業時間外の枠を返さない" do
    skip "WeeklySlotFinder は画面①（週カレンダー）の段階で実装する（別紙A A-2-3 / §8 実装順4）"
  end

  test "16. 2名選択時、片方だけ埋まっている区間は all_available? が false" do
    busy = User.create!(name: "予定 花子", email: "busy@example.com", interviewer: true)
    busy.calendar_events.create!(source: "external", title: "他案件",
                                 start_at: Time.zone.parse("#{BASE_DAY} 14:30"),
                                 end_at: Time.zone.parse("#{BASE_DAY} 15:30"))

    loaded = User.includes(:availability_rules, :calendar_events)
                 .where(id: [ @user.id, busy.id ]).to_a
    chk = checker("#{BASE_DAY} 14:00", "#{BASE_DAY} 15:00")

    assert_not chk.all_available?(loaded)

    results = chk.call(loaded).index_by { |r| r.user.id }
    assert results[@user.id].available
    assert_not results[busy.id].available
    assert_equal "予定あり（他案件）", results[busy.id].reason
  end
end
