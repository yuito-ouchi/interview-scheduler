module InterviewsHelper
  # 週カレンダーの縦スケール。1分あたりのピクセル数。
  PX_PER_MIN = 0.8
  WDAY_JA = %w[日 月 火 水 木 金 土].freeze

  # 週内の全営業時間を包含する表示レンジ [開始分, 終了分]（0時起点の分）。
  # 営業日が1つもなければ [nil, nil]。
  def calendar_bounds(days)
    open = days.reject(&:closed?)
    return [ nil, nil ] if open.empty?

    [ open.map { |d| minutes_of_day(d.open_from) }.min,
      open.map { |d| minutes_of_day(d.open_to) }.max ]
  end

  def minutes_of_day(time)
    (time.hour * 60) + time.min
  end

  # 区間を表示レンジ内に配置する top/height（px）。潰れないよう最小高を確保する。
  def segment_style(view_from_min, start_at, end_at)
    top    = (minutes_of_day(start_at) - view_from_min) * PX_PER_MIN
    height = ((end_at - start_at) / 60.0) * PX_PER_MIN
    "top:#{top.round(1)}px;height:#{[ height, 14 ].max.round(1)}px"
  end

  # その日の予定（source を問わず calendar_events すべて）。ラベル用に氏名を添える。
  def day_events(users, date)
    users.flat_map do |user|
      user.calendar_events
          .select { |e| e.start_at.to_date == date || e.end_at.to_date == date }
          .map { |e| { name: user.name, title: e.title, all_day: e.all_day?,
                       start_at: e.start_at, end_at: e.end_at } }
    end
  end

  # その日の予約不可時間（テナント block ∪ 個人 block ／ BR-12）。
  def day_blocks(users, tenant_rules, date)
    personal = users.flat_map(&:availability_rules)
    (tenant_rules + personal)
      .select { |r| r.rule_type == "block" && r.day_of_week == date.wday }
      .map { |r| { label: r.label, start_at: rule_at(date, r.start_time), end_at: rule_at(date, r.end_time) } }
      .uniq { |b| [ b[:label], b[:start_at], b[:end_at] ] }
  end

  def rule_at(date, time_value)
    Time.zone.local(date.year, date.month, date.day, time_value.hour, time_value.min)
  end

  def hhmm(time)
    time.strftime("%-H:%M")
  end

  def wday_ja(date)
    WDAY_JA[date.wday]
  end
end
