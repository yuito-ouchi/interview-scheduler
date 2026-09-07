Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # ログイン・主催者/参加者の自己登録（F-05 / 仕様書 §6.2 ／ 判断メモ D-12：Devise）。
  # /auth 以下に分けているのは、既に /users を管理者限定のメンバー管理CRUD
  # （resources :users）で使っており、Devise標準の devise_for :users のままだと
  # /users/sign_in 等が衝突するため。
  devise_for :users, path: "auth", controllers: { registrations: "registrations" }

  # 画面①（ミーティングを組む）＋ 予約フォーム・確定・一覧・編集・キャンセル
  resources :meetings do
    get :calendar, on: :collection # Turbo Frame で選択メンバーの週カレンダーを返す
  end

  # 画面③ メンバー管理（設定）。admin のみ操作できる（UsersController 側で制御）
  resources :users

  # 設定の子ページ：テナント全体の営業時間（allow）と固定ブロック（block）。
  # 1画面に集約している（判断メモ D-11 / D-13）。admin のみ操作できる
  resources :tenant_rules, except: [ :show ]

  root "meetings#new"
end
