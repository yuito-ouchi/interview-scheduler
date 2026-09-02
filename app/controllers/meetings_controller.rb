class MeetingsController < ApplicationController
  # GET /meetings/new
  # 参加者選択＋週カレンダー。空き枠リンク（?start_at=...）で来たときは
  # 予約フォーム（booking_form フレーム）も一緒に組み立てる（§6.6 手順5）。
  def new
    assign_params
    @participants = User.where(participant: true).order(:name)
    load_calendar if @user_ids.any?
    prepare_booking if params[:start_at].present?
  end

  # GET /meetings/calendar
  # フォーム送信・週送りの受け口。週カレンダー部分だけ差し替える。
  def calendar
    assign_params
    load_calendar if @user_ids.any?
    render partial: "week_grid"
  end

  # GET /meetings/:id
  def show
    @meeting = Meeting.includes(:attendees, calendar_events: :user).find(params[:id])
  end

  # POST /meetings
  # §6.6 手順7 ／ §5 ／ A-3：確定直前にトランザクション内で再判定する。
  def create
    @user_ids = selected_user_ids
    @meeting  = Meeting.new(meeting_params.merge(created_by: current_user))

    if confirm_booking
      redirect_to @meeting, notice: "予約を確定しました"
    else
      rerender_new_with_booking
    end
  end

  private

  def assign_params
    @user_ids = selected_user_ids
    @duration = duration_param
    @week_of  = week_of_param
  end

  def selected_user_ids
    Array(params[:user_ids]).reject(&:blank?).map(&:to_i)
  end

  # プリセットは 15/30/45/60/90 だが制約ではない（BR-08）。正の整数なら受ける。
  def duration_param
    d = params[:duration].to_i
    d.positive? ? d : 60
  end

  # A-1/A-4：文字列からの生成は Time.zone.parse のみ。壊れた入力は今週にフォールバック。
  def week_of_param
    (parse_time(params[:week_of]) || Time.current).beginning_of_week
  end

  def parse_time(raw)
    return if raw.blank?

    Time.zone.parse(raw)
  rescue ArgumentError, Date::Error
    nil
  end

  # A-2-4：予定とルールを事前読み込みし、区間ごとにDBを叩かない。
  def load_calendar
    @tenant_rules = AvailabilityRule.where(user_id: nil).to_a
    @users = User.where(id: @user_ids, participant: true)
                 .includes(:availability_rules)
                 .order(:name)
                 .to_a
    attach_week_events(@users, @week_of.all_week)

    @days = WeeklySlotFinder.new(users: @users, week_of: @week_of,
                                 duration_min: @duration,
                                 tenant_rules: @tenant_rules).call
  end

  # 全員分の予定を1クエリで取り、週の範囲に絞って各 user の association に載せる。
  # 以後 user.calendar_events はこの配列を返し、追加クエリを発行しない。
  def attach_week_events(users, week_range)
    by_user = CalendarEvent.where(user_id: users.map(&:id), start_at: week_range).group_by(&:user_id)
    users.each do |user|
      assoc = user.association(:calendar_events)
      assoc.target = by_user.fetch(user.id, [])
      assoc.loaded!
    end
  end

  # 空き枠リンクから来たときの予約フォーム用インスタンス。
  def prepare_booking
    start_at = parse_time(params[:start_at])
    end_at   = parse_time(params[:end_at])
    return if start_at.nil? || end_at.nil?

    @meeting ||= Meeting.new(start_at: start_at, end_at: end_at, location_type: "online")
    @selected_participants = User.where(id: @user_ids, participant: true).order(:name).to_a
    @booking = @selected_participants.any?
  end

  # 確定に失敗したとき、画面①を丸ごと描き直す（カレンダーとフォームの両方）。
  def rerender_new_with_booking
    assign_params
    @participants = User.where(participant: true).order(:name)
    load_calendar if @user_ids.any?
    @selected_participants = User.where(id: @user_ids, participant: true).order(:name).to_a
    @booking = @meeting.start_at.present? && @meeting.end_at.present? && @selected_participants.any?
    render :new, status: :unprocessable_entity
  end

  # BR-06 / §5 / A-3。
  # Rails 8.1 の SQLite3 アダプタは全トランザクションを `BEGIN IMMEDIATE` で開始するため
  # （検証済み。`isolation: :immediate` 引数は TransactionIsolationError で拒否される）、
  # 素の transaction ブロックで開始時に書き込みロックを取れる。
  # 戻り値：確定できたら true、できなければ false（@booking_error か @meeting.errors に理由）。
  def confirm_booking
    return false unless @meeting.valid?(:create) # 過去日時・必須項目・区間はここで弾く（§9.3-1）

    ActiveRecord::Base.transaction do
      users = User.where(id: @user_ids, participant: true)
                  .includes(:availability_rules, :calendar_events)
                  .order(:id)
                  .to_a

      if users.empty?
        @booking_error = "参加者が選択されていません"
        raise ActiveRecord::Rollback
      end

      # 検索時とまったく同じ AvailabilityChecker で、選択メンバーだけ再判定する。
      tenant_rules = AvailabilityRule.where(user_id: nil).to_a
      results = AvailabilityChecker
                .new(start_at: @meeting.start_at, end_at: @meeting.end_at, tenant_rules: tenant_rules)
                .call(users)
      busy = results.reject(&:available)

      if busy.any?
        # BR-06：1名でも不可なら予約全体を中止（部分確定はしない）
        @booking_error = "#{busy.map { |r| r.user.name }.join('・')} さんの予定が埋まりました。枠を選び直してください。"
        raise ActiveRecord::Rollback
      end

      @meeting.save!
      users.each do |user|
        @meeting.meeting_attendees.create!(user: user)
        # §3.3(1)：ミーティングの記録とは別に、時間の占有を出席者ごとに1件書く。
        # source: "app" と meeting を設定しないと、次の検索で自分のミーティングが
        # 空き判定から漏れて自分でダブルブッキングする。
        @meeting.calendar_events.create!(
          user: user, source: "app", all_day: false,
          title: @meeting.calendar_title, # BR-11：ミーティング：{ゲスト名}様（編集不可）
          start_at: @meeting.start_at, end_at: @meeting.end_at
        )
      end

      true
    end
  rescue ActiveRecord::RecordInvalid
    false
  end

  def meeting_params
    params.expect(meeting: %i[guest_name location_type location_text meet_url])
          .merge(start_at: resolved_start_at, end_at: resolved_end_at)
  end

  # 予約フォームはミーティング日（date）を①から引き継ぎ、開始時刻・所要時間はBR-08に
  # 合わせて自由入力にしている（date + start_time + duration から組み立てる）。
  def resolved_start_at
    return nil if params[:date].blank? || params[:start_time].blank?

    parse_time("#{params[:date]} #{params[:start_time]}")
  end

  def resolved_end_at
    start_at = resolved_start_at
    return nil if start_at.nil?

    start_at + duration_param.minutes
  end
end
