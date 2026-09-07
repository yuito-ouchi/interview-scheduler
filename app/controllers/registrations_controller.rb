class RegistrationsController < Devise::RegistrationsController
  # Deviseの registerable はデフォルトで「自分のアカウントを自分で削除できる」
  # 機能（DELETE /auth）も持つ。これを有効にすると、D-8で塞いだ穴（今後の
  # ミーティングに出席予定の人が消えると、そのミーティングの出席者・占有だけが
  # 黙って消える）が自己削除という別経路から再び開いてしまう。削除はadminの
  # メンバー管理（D-4／UsersController#destroy）に一本化する（判断メモ D-12）。
  def destroy
    redirect_to root_path, alert: "アカウントの削除は管理者にご依頼ください"
  end
end
