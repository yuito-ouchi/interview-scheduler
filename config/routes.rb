Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # 簡易ログイン（F-05 / 仕様書 §6.2）。パスワード認証はしない
  get  "login", to: "sessions#new"
  post "login", to: "sessions#create"

  # 画面①（面接を組む）＋ 予約フォーム・確定。一覧（index）は次段階
  resources :interviews, only: %i[new create show] do
    get :calendar, on: :collection # Turbo Frame で選択メンバーの週カレンダーを返す
  end

  root "interviews#new"
end
