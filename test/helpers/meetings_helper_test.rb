require "test_helper"

# calendar_bounds の境界条件。営業時間をまたぐ予定（seeds.rb の「社外研修」の
# ような 9:00-19:00 の外部予定）を含めないと、segment_style が負の top を
# 返し、.week-grid__body の overflow:hidden で見切れて表示される不具合が
# あったため、そのケースを固定する。
class MeetingsHelperTest < ActionView::TestCase
  include MeetingsHelper

  Day = WeeklySlotFinder::Day

  test "calendar_bounds：営業日が1つもなければ [nil, nil]" do
    days = [ Day.new(date: Date.new(2026, 9, 5), open_from: nil, open_to: nil, slots: [], free_windows: []) ]
    assert_equal [ nil, nil ], calendar_bounds(days)
  end

  test "calendar_bounds：予定を渡さなければ営業時間だけがレンジになる（従来通り）" do
    days = [ open_day(Time.zone.local(2026, 9, 1, 10, 0), Time.zone.local(2026, 9, 1, 18, 0)) ]
    assert_equal [ 10 * 60, 18 * 60 ], calendar_bounds(days)
  end

  test "calendar_bounds：営業時間をまたぐ予定があればレンジを広げる" do
    days = [ open_day(Time.zone.local(2026, 9, 1, 10, 0), Time.zone.local(2026, 9, 1, 18, 0)) ]
    events = [ { start_at: Time.zone.local(2026, 9, 1, 9, 0), end_at: Time.zone.local(2026, 9, 1, 19, 0) } ]

    assert_equal [ 9 * 60, 19 * 60 ], calendar_bounds(days, events)
  end

  test "calendar_bounds：予定が営業時間内に収まっていればレンジは変わらない" do
    days = [ open_day(Time.zone.local(2026, 9, 1, 10, 0), Time.zone.local(2026, 9, 1, 18, 0)) ]
    events = [ { start_at: Time.zone.local(2026, 9, 1, 13, 0), end_at: Time.zone.local(2026, 9, 1, 14, 0) } ]

    assert_equal [ 10 * 60, 18 * 60 ], calendar_bounds(days, events)
  end

  private

  def open_day(open_from, open_to)
    Day.new(date: open_from.to_date, open_from: open_from, open_to: open_to, slots: [], free_windows: [])
  end
end
