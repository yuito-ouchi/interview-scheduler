class MeetingsController < ApplicationController
  before_action :set_meeting, only: %i[show edit update destroy]

  # GET /meetings/new
  # 参加者選択＋週カレンダー。空き枠リンク（?start_at=...）で来たときは
  # 予約フォーム（booking_form フレーム）も一緒に組み立てる（§6.6 手順5）。
  def new
    assign_params
    @participants = User.order(:name)
    load_calendar if @user_ids.any?
    prepare_booking if params[:start_at].present?
  end

  # GET /meetings/calendar
  # フォーム送信・週送りの受け口。週カレンダー部分だけ差し替える。
  def calendar
    assign_params
    @participants = User.order(:name)
    load_calendar if @user_ids.any?
    render partial: "calendar_frame"
  end

  # GET /meetings
  # 登録者で絞り込まず全件共有（仕様書§6.7）。今後の予約のみ（§9.1）。
  # ?q= でゲスト名・参加者名・登録者名を横断検索する（判断メモ D-10）。
  def index
    @query = params[:q].to_s.strip
    @meetings = Meeting.includes(:attendees, :created_by).upcoming
    @meetings = @meetings.merge(search_meetings(@query)) if @query.present?
  end

  # GET /meetings/:id
  def show
    @meeting = Meeting.includes(:attendees, :created_by).find(params[:id])
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

  # GET /meetings/:id/edit
  # F-25：日時・所要時間・ゲスト情報に加え、参加者の選び直しもできる（判断メモ D-14）。
  #
  # 画面①と同じ週カレンダーとサイドバー（参加者チェック・所要時間）を添えて、
  # 空き状況を見ながら日時と参加者を選び直せるようにする（判断メモ D-9・D-14）。
  # start_at/end_at がクエリで来ていれば「カレンダーの空き帯をクリックした直後」
  # なのでフォームの日時をそれに差し替える（保存はまだしない）。
  # 無ければ初回表示＝現在の予約日時のまま。
  def edit
    apply_proposed_slot
    @participants = User.order(:name)
    @user_ids     = edit_user_ids
    @week_of      = params[:week_of].present? ? week_of_param : @meeting.start_at.beginning_of_week
    load_edit_calendar if @user_ids.any?
  end

  # PATCH /meetings/:id
  def update
    @duration = duration_param
    # 参加者はフォームの hidden field（サイドバーで選んだ結果）で届く（D-14）。
    # user_ids キーそのものが無いリクエスト（日時だけを送る形）では参加者を現状維持にする。
    # edit と同じ規則（edit_user_ids）。
    @user_ids = edit_user_ids

    if confirm_update
      redirect_to @meeting, notice: "予約を変更しました"
    else
      # edit ビューは週カレンダーとサイドバーも描画するため、失敗時も同じ材料を揃える。
      # confirm_update は失敗時も @meeting.start_at/end_at を送信された（弾かれた）
      # 値のまま残すため、その週を表示すれば「なぜ弾かれたか」がそのまま見える
      # （date/start_time が未入力で弾かれた場合だけ start_at が nil なので今週にフォールバック）。
      @participants = User.order(:name)
      @week_of = (@meeting.start_at || Time.current).beginning_of_week
      load_edit_calendar if @user_ids.any?
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /meetings/:id
  # F-26：キャンセル。calendar_events・meeting_attendees は dependent: :destroy で連動削除される。
  def destroy
    @meeting.destroy
    redirect_to meetings_path, notice: "#{@meeting.guest_name} 様とのミーティングをキャンセルしました",
      status: :see_other
  end

  private

  def set_meeting
    @meeting = Meeting.includes(:attendees).find(params[:id])
  end

  # ゲスト名（部分一致）／出席者名／登録者名のいずれかに一致するミーティングに絞る。
  # attendees（has_many through）と created_by（belongs_to）を同じクエリで
  # LEFT JOIN すると users テーブルの別名が衝突するため、サブクエリのIN で合成する。
  def search_meetings(query)
    like = "%#{Meeting.sanitize_sql_like(query)}%"
    attendee_meeting_ids = MeetingAttendee.joins(:user).where("users.name LIKE ?", like).select(:meeting_id)
    creator_ids = User.where("name LIKE ?", like).select(:id)

    Meeting.where(
      "guest_name LIKE :like OR id IN (:attendee_meeting_ids) OR created_by_id IN (:creator_ids)",
      like: like, attendee_meeting_ids: attendee_meeting_ids, creator_ids: creator_ids
    )
  end

  def assign_params
    @user_ids = selected_user_ids
    @duration = duration_param
    @week_of  = week_of_param
  end

  def selected_user_ids
    Array(params[:user_ids]).reject(&:blank?).map(&:to_i)
  end

  # 編集画面で表示する参加者。user_ids パラメータが来ていればそれ（＝サイドバーで
  # 選び直した結果）、来ていなければ現在の出席者（＝初回表示）。
  #
  # 「1つもチェックしない」状態を表現できるよう、サイドバーのフォームには空文字の
  # hidden field を必ず1つ置いている。チェックボックスだけだと全部外したときに
  # user_ids キー自体が送られず、「全部外した」と「初回表示」を区別できない。
  def edit_user_ids
    params.key?(:user_ids) ? selected_user_ids : @meeting.attendees.map(&:id)
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
    @users = User.where(id: @user_ids)
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
  # exclude_meeting を渡すと、そのミーティング自身の占有（calendar_events）を除く
  # （F-25の編集画面用。除かないと「自分自身の予定と重なる＝不可」に必ずなる。
  # confirm_update の再判定と同じ理由）。
  #
  # 除外は meeting_id の不一致ではなく「id で個別に除く」形にすること。
  # calendar_events.meeting_id は source=app の行にしか入らず、外部予定
  # （source=external）は必ず NULL（別紙A・仕様書§3.3(2)）。SQLの
  # `WHERE meeting_id != X` は NULL 行を「一致も不一致も判定不能」として
  # 結果から落としてしまうため、`where.not(meeting_id: ...)` だと外部予定が
  # 全部消える（3値論理の罠。実際にこのバグで編集画面から他の予定が消えていた）。
  def attach_week_events(users, week_range, exclude_meeting: nil)
    scope = CalendarEvent.where(user_id: users.map(&:id), start_at: week_range)
    scope = scope.where.not(id: exclude_meeting.calendar_events.select(:id)) if exclude_meeting
    by_user = scope.group_by(&:user_id)
    users.each do |user|
      assoc = user.association(:calendar_events)
      assoc.target = by_user.fetch(user.id, [])
      assoc.loaded!
    end
  end

  # F-25の編集画面用の週カレンダー。load_calendar との違いは「このミーティング
  # 自身の占有を判定対象から除く」点だけ（除かないと、自分自身の既存予定と必ず
  # ぶつかって全区間が不可になる。confirm_update の再判定と同じ理由）。
  # 対象メンバーは @user_ids＝サイドバーで選ばれている参加者（D-14）。
  def load_edit_calendar
    @tenant_rules = AvailabilityRule.where(user_id: nil).to_a
    @users = User.where(id: @user_ids)
                 .includes(:availability_rules)
                 .order(:name)
                 .to_a
    attach_week_events(@users, @week_of.all_week, exclude_meeting: @meeting)

    @days = WeeklySlotFinder.new(users: @users, week_of: @week_of,
                                 duration_min: @duration,
                                 tenant_rules: @tenant_rules).call
  end

  # edit の GET パラメータ（カレンダーの空き帯クリック直後）で日時・所要時間を
  # 差し替える。保存はしない（フォーム表示用に @meeting をその場で書き換えるだけ）。
  # 無指定なら現在の予約日時のまま＝初回表示。
  def apply_proposed_slot
    @duration = params[:duration].present? ? duration_param : ((@meeting.end_at - @meeting.start_at) / 60).round
    start_at = parse_time(params[:start_at])
    end_at   = parse_time(params[:end_at])
    return if start_at.nil? || end_at.nil?

    @meeting.start_at = start_at
    @meeting.end_at   = end_at
  end

  # 空き枠リンクから来たときの予約フォーム用インスタンス。
  def prepare_booking
    start_at = parse_time(params[:start_at])
    end_at   = parse_time(params[:end_at])
    return if start_at.nil? || end_at.nil?

    @meeting ||= Meeting.new(start_at: start_at, end_at: end_at, location_type: "online")
    @selected_participants = User.where(id: @user_ids).order(:name).to_a
    @booking = @selected_participants.any?
  end

  # 確定に失敗したとき、画面①を丸ごと描き直す（カレンダーとフォームの両方）。
  def rerender_new_with_booking
    assign_params
    @participants = User.order(:name)
    load_calendar if @user_ids.any?
    @selected_participants = User.where(id: @user_ids).order(:name).to_a
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
      users = User.where(id: @user_ids)
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

  # F-25：変更時の再判定。confirm_booking とほぼ同じで、違いは2つだけ。
  #
  # 1. 判定対象は「送信された参加者」（＝サイドバーで選び直した結果。D-14）。
  #    新しく追加された人も、確定直前にこの再判定を通る（BR-06：1名でも不可なら
  #    変更全体を中止）。
  # 2. 「このミーティング自身の占有」を判定対象の予定から除外する。除外しないと、
  #    変更のたびに自分自身の既存予定と必ずぶつかって「不可」になってしまう。
  def confirm_update
    @meeting.assign_attributes(edit_params)
    return false unless @meeting.valid?(:update)

    ActiveRecord::Base.transaction do
      # 出席者・占有を作り直す前に、除外対象の占有idを控えておく。
      own_event_ids = @meeting.calendar_events.pluck(:id)
      users = User.where(id: @user_ids)
                  .includes(:availability_rules, :calendar_events)
                  .order(:id)
                  .to_a

      if users.empty?
        @booking_error = "参加者が選択されていません"
        raise ActiveRecord::Rollback
      end

      users.each do |user|
        assoc = user.association(:calendar_events)
        assoc.target = assoc.target.reject { |e| own_event_ids.include?(e.id) }
      end

      tenant_rules = AvailabilityRule.where(user_id: nil).to_a
      results = AvailabilityChecker
                .new(start_at: @meeting.start_at, end_at: @meeting.end_at, tenant_rules: tenant_rules)
                .call(users)
      busy = results.reject(&:available)

      if busy.any?
        @booking_error = "#{busy.map { |r| r.user.name }.join('・')} さんの予定が埋まりました。日時か参加者を選び直してください。"
        raise ActiveRecord::Rollback
      end

      @meeting.save!
      sync_attendees_and_events!(users)

      true
    end
  rescue ActiveRecord::RecordInvalid
    false
  end

  # 参加者の増減に合わせて meeting_attendees と calendar_events を作り直す（D-14）。
  #
  # 外した人の占有（calendar_events）を消し忘れると、出席しないミーティングの
  # 占有だけがその人のカレンダーに残り、以後の空き判定を誤らせる。逆に追加した人の
  # 占有を作り忘れると、次の検索でその人が空いていることになりダブルブッキングする
  # （変えてはいけない設計判断3と同じ理由）。増減と時刻変更を一度にやるため、
  # 「残す人以外を消す → 残す人は更新、増えた人は作る」の順で揃える。
  def sync_attendees_and_events!(users)
    keep_ids = users.map(&:id)

    @meeting.meeting_attendees.where.not(user_id: keep_ids).destroy_all
    @meeting.calendar_events.where.not(user_id: keep_ids).destroy_all

    existing_events = @meeting.calendar_events.reload.index_by(&:user_id)

    users.each do |user|
      @meeting.meeting_attendees.find_or_create_by!(user_id: user.id)

      if (event = existing_events[user.id])
        event.update!(start_at: @meeting.start_at, end_at: @meeting.end_at,
                      title: @meeting.calendar_title)
      else
        # §3.3(1)：source: "app" と meeting_id を必ず入れる（設計判断3）。
        @meeting.calendar_events.create!(
          user: user, source: "app", all_day: false,
          title: @meeting.calendar_title,
          start_at: @meeting.start_at, end_at: @meeting.end_at
        )
      end
    end

    @meeting.attendees.reset
  end

  def meeting_params
    params.expect(meeting: %i[guest_name location_type location_text meet_url])
          .merge(start_at: resolved_start_at, end_at: resolved_end_at)
  end

  def edit_params
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
