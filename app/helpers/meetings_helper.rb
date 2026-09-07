module MeetingsHelper
  # 週カレンダーの縦スケール。1分あたりのピクセル数。
  PX_PER_MIN = 1.0
  WDAY_JA = %w[日 月 火 水 木 金 土].freeze

  # 週内の全営業時間を包含する表示レンジ [開始分, 終了分]（0時起点の分）。
  # 営業日が1つもなければ [nil, nil]。
  #
  # events を渡すと、営業時間をまたぐ予定（例：9:00-19:00の終日でない外部予定が
  # 10:00-18:00の営業時間をはみ出す）の分もレンジに含める。渡さなければ従来通り
  # 営業時間のみ。含めないと、はみ出した予定が negative top や height 超過になり
  # position:absolute + overflow:hidden の .week-grid__body に切れて表示される
  # （見た目上「見切れる」不具合になっていた）。
  def calendar_bounds(days, events = [])
    open = days.reject(&:closed?)
    return [ nil, nil ] if open.empty?

    from = open.map { |d| minutes_of_day(d.open_from) } + events.map { |e| minutes_of_day(e[:start_at]) }
    to   = open.map { |d| minutes_of_day(d.open_to) }   + events.map { |e| minutes_of_day(e[:end_at]) }

    [ from.min, to.max ]
  end

  def minutes_of_day(time)
    (time.hour * 60) + time.min
  end

  # 時刻軸に並べる正時のリスト。表示レンジ [view_from_min, view_to_min]（0時起点の分）
  # に収まる毎時 h を返す。tick_top と合わせて縦位置を出す。
  def hour_ticks(view_from_min, view_to_min)
    ((view_from_min / 60.0).ceil..(view_to_min / 60.0).floor).to_a
  end

  # 正時 hour（0-23）を表示レンジ内に配置する top（px）。segment_style と同じスケール。
  def tick_top(hour, view_from_min)
    ((hour * 60) - view_from_min) * PX_PER_MIN
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

  # 複数人の予定を1つのカレンダーに重ねて表示するため（変えてはいけない設計判断・
  # CLAUDE.md）、同じ時間帯に別々の人の「予定あり」が重なることがある。
  # 時刻だけで絶対配置すると完全に重なって読めなくなるので、区間彩色の貪欲法で
  # 列を割り当て、横に並べて見せる。件数が少ない前提の簡易実装（全列を１クラスタ
  # 扱いにする分、まれに必要以上に幅を詰めることがあるが、実害はない）。
  def layout_busy(events)
    column_ends = []
    placed = events.sort_by { |e| e[:start_at] }.map do |ev|
      col = column_ends.find_index { |end_at| end_at <= ev[:start_at] } || column_ends.size
      column_ends[col] = ev[:end_at]
      ev.merge(col: col)
    end
    placed.map { |ev| ev.merge(col_count: column_ends.size) }
  end

  # layout_busy が振った列番号から、横方向の位置とサイズを CSS で返す。
  def column_style(col, col_count)
    return "" if col_count <= 1

    width = 100.0 / col_count
    "left:calc(#{(width * col).round(3)}% + 2px);right:auto;width:calc(#{width.round(3)}% - 4px)"
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
